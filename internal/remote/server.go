package remote

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"dit/internal/bundle"
	"dit/internal/model"
	"dit/internal/store"
)

// errNoPrecondition marks a write that arrived without an If-Match: it is
// 412 Precondition Failed, distinct from a stale (409) precondition.
var errNoPrecondition = errors.New("no If-Match precondition — read the document first")

// Server exposes one local portfolio over the dit remote protocol.
type Server struct {
	Ledger    store.Store
	Market    store.Store
	Token     string
	Immutable bool
	Version   string

	mu sync.Mutex
}

// NewServer returns an HTTP handler.
func NewServer(ledger, market store.Store, token string, immutable bool, version string) http.Handler {
	s := &Server{Ledger: ledger, Market: market, Token: strings.TrimSpace(token), Immutable: immutable, Version: version}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/info", s.info)
	mux.HandleFunc("GET /api/v1/store/{key}", s.getDocument)
	mux.HandleFunc("PUT /api/v1/store/{key}", s.putDocument)
	mux.HandleFunc("GET /api/v1/bundle", s.bundle)
	mux.HandleFunc("PUT /api/v1/documents", s.putDocuments)
	mux.HandleFunc("/", s.root)
	return s.auth(mux)
}

func (s *Server) root(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"schema": Schema,
		"hint":   "this is a dit remote server — use /api/v1/info",
	})
}

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.Token != "" {
			token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(token), []byte(s.Token)) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required — use the token shown by 'dit serve'"})
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, Info{
		Schema:      Schema,
		Version:     s.Version,
		Immutable:   s.Immutable,
		AuthEnabled: s.Token != "",
	})
}

func (s *Server) document(key string) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.documentLocked(key)
}

func (s *Server) documentLocked(key string) ([]byte, error) {
	var source store.Store
	switch key {
	case store.PortfolioKey:
		source = s.Ledger
	case store.MarketKey:
		source = s.Market
	default:
		return nil, fmt.Errorf("unknown document '%s' (expected %s or %s)", key, store.PortfolioKey, store.MarketKey)
	}
	return source.Load(key)
}

func (s *Server) checkETagLocked(key, provided string) error {
	current, err := s.documentLocked(key)
	if err != nil {
		return err
	}
	want := ETag(current)
	if provided == "" {
		return errNoPrecondition
	}
	if subtle.ConstantTimeCompare([]byte(provided), []byte(want)) != 1 {
		return fmt.Errorf("the document changed since it was read — re-read and retry")
	}
	return nil
}

// preconditionStatus maps a checkETagLocked failure to its HTTP status.
func preconditionStatus(err error) int {
	if errors.Is(err, errNoPrecondition) {
		return http.StatusPreconditionFailed
	}
	return http.StatusConflict
}

func (s *Server) getDocument(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	key := r.PathValue("key")
	data, err := s.document(key)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("ETag", ETag(data))
	w.Header().Set("Cache-Control", "no-store")
	if data == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(data)
}

func (s *Server) validate(key string, data []byte) error {
	switch key {
	case store.PortfolioKey:
		_, err := bundle.DecodePortfolio(data)
		return err
	case store.MarketKey:
		var market model.MarketData
		if err := json.Unmarshal(data, &market); err != nil {
			return fmt.Errorf("market data is not valid JSON: %v", err)
		}
		return nil
	default:
		return fmt.Errorf("unknown document '%s'", key)
	}
}

func (s *Server) saveLocked(key string, data []byte) error {
	if key == store.MarketKey {
		return s.Market.Save(key, data)
	}
	return s.Ledger.Save(key, data)
}

func (s *Server) putDocument(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w)
		return
	}
	if s.Immutable {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "this server is running with --immutable — remote writes are disabled"})
		return
	}
	key := r.PathValue("key")
	if key != store.PortfolioKey && key != store.MarketKey {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown document '" + key + "'"})
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.checkETagLocked(key, r.Header.Get("If-Match")); err != nil {
		writeJSON(w, preconditionStatus(err), map[string]string{"error": err.Error()})
		return
	}
	if err := s.validate(key, body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if err := s.saveLocked(key, body); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("ETag", ETag(body))
	writeJSON(w, http.StatusOK, map[string]string{"ok": "true"})
}

// maxBody caps a request body; a body over the cap is refused, not truncated.
const maxBody = 200 << 20

func readBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request body cannot be read"})
		return nil, err
	}
	if len(data) > maxBody {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request body is too large (200 MB limit)"})
		return nil, fmt.Errorf("body too large")
	}
	return data, nil
}

func (s *Server) bundle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	portfolio, err := s.Ledger.Load(store.PortfolioKey)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	market, err := s.Market.Load(store.MarketKey)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if portfolio == nil && market == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "the remote portfolio is empty — there is nothing to clone"})
		return
	}
	var p *model.Portfolio
	if portfolio != nil {
		var parsed model.Portfolio
		if err := json.Unmarshal(portfolio, &parsed); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "stored portfolio is not valid JSON"})
			return
		}
		p = &parsed
	}
	m := store.EmptyMarket()
	if market != nil {
		if err := json.Unmarshal(market, &m); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "stored market data is not valid JSON: " + err.Error()})
			return
		}
	}
	doc := bundle.Document{Schema: bundle.Schema, CreatedAt: model.Stamp(time.Now().UnixNano()) / 1e9, Portfolio: p}
	if portfolio == nil || !m.IsEmpty() {
		doc.Market = &m
	}
	data, err := bundle.Encode(doc)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(data)
}

func (s *Server) putDocuments(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut {
		methodNotAllowed(w)
		return
	}
	if s.Immutable {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "this server is running with --immutable — remote writes are disabled"})
		return
	}
	body, err := readBody(w, r)
	if err != nil {
		return
	}
	var request struct {
		Portfolio     *string `json:"portfolio"`
		PortfolioEtag string  `json:"portfolioEtag"`
		Market        *string `json:"market"`
		MarketEtag    string  `json:"marketEtag"`
	}
	if err := json.Unmarshal(body, &request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid document update"})
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Preconditions first, then strict validation of every document, before
	// anything is written: a failed validation must never leave one half of
	// the pair committed.
	if request.Portfolio != nil {
		if err := s.checkETagLocked(store.PortfolioKey, request.PortfolioEtag); err != nil {
			writeJSON(w, preconditionStatus(err), map[string]string{"error": err.Error()})
			return
		}
		if err := s.validate(store.PortfolioKey, []byte(*request.Portfolio)); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}
	if request.Market != nil {
		if err := s.checkETagLocked(store.MarketKey, request.MarketEtag); err != nil {
			writeJSON(w, preconditionStatus(err), map[string]string{"error": err.Error()})
			return
		}
		if err := s.validate(store.MarketKey, []byte(*request.Market)); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}
	// A rollback is only possible if a market write failure would leave the
	// portfolio half already committed, so the snapshot is needed only when
	// both documents are written.
	var rollback func() error
	if request.Portfolio != nil && request.Market != nil {
		original, err := s.Ledger.Load(store.PortfolioKey)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cannot read the current portfolio for a rollback: " + err.Error()})
			return
		}
		rollback = func() error {
			if original == nil {
				return s.Ledger.Delete(store.PortfolioKey)
			}
			return s.Ledger.Save(store.PortfolioKey, original)
		}
	}
	if request.Portfolio != nil {
		if err := s.Ledger.Save(store.PortfolioKey, []byte(*request.Portfolio)); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the portfolio write failed: " + err.Error()})
			return
		}
	}
	if request.Market != nil {
		if err := s.Market.Save(store.MarketKey, []byte(*request.Market)); err != nil {
			if rollback != nil {
				if rbErr := rollback(); rbErr != nil {
					writeJSON(w, http.StatusInternalServerError, map[string]string{
						"error": "the market write failed AND restoring the previous portfolio failed (" + rbErr.Error() + ") — the local portfolio may be stale; re-run the command",
					})
					return
				}
			}
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the market write failed — the paired write was rolled back, the portfolio is unchanged"})
			return
		}
	}
	response := map[string]any{"ok": "true", "etags": map[string]string{}}
	if request.Portfolio != nil {
		(response["etags"]).(map[string]string)[store.PortfolioKey] = ETag([]byte(*request.Portfolio))
	}
	if request.Market != nil {
		(response["etags"]).(map[string]string)[store.MarketKey] = ETag([]byte(*request.Market))
	}
	writeJSON(w, http.StatusOK, response)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func methodNotAllowed(w http.ResponseWriter) {
	writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
}
