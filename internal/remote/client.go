// Package remote implements dit's machine-to-machine protocol.
//
// A server exposes the two portfolio documents plus a bundle endpoint over
// plain HTTP. A client wraps those endpoints in the same `store.Store`
// abstraction the local backends use, so the whole command surface can run
// against a remote portfolio without learning a second persistence model.
package remote

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"dit/internal/store"
)

// Schema is the protocol identifier exchanged by `connect` before use.
const Schema = "dit-remote/1"

// DefaultPort is used when a target names a host but no port.
const DefaultPort = 8348

// DefaultServePort is the listener port for a bare `dit serve`.
const DefaultServePort = DefaultPort

// Info describes a running server.
type Info struct {
	Schema      string `json:"schema"`
	Version     string `json:"version,omitempty"`
	Immutable   bool   `json:"immutable"`
	AuthEnabled bool   `json:"authEnabled"`
}

// ClientError is a protocol failure with an HTTP status.
type ClientError struct {
	Status  int
	Message string
}

func (e *ClientError) Error() string { return e.Message }

// Connection is one active remote endpoint, with a per-invocation cache.
type Connection struct {
	Target   string
	Address  string
	BaseURL  string
	Token    string
	ReadOnly bool

	client   *http.Client
	mu       sync.Mutex
	payloads map[string][]byte
	etags    map[string]string
	loaded   map[string]bool
}

// NormalizeTarget accepts `host:port`, `http://host:port` or a bare host
// (DefaultPort is assumed) and returns the user-facing address plus base URL.
func NormalizeTarget(raw string) (address, baseURL string, err error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		err = fmt.Errorf("empty remote target")
		return
	}
	if !strings.Contains(value, "://") {
		value = "http://" + value
	}
	u, parseErr := url.Parse(value)
	if parseErr != nil || u.Host == "" {
		err = fmt.Errorf("invalid remote target '%s' — use HOST:PORT", raw)
		return
	}
	if u.Scheme != "http" {
		err = fmt.Errorf("invalid remote target '%s' — dit serve speaks plain HTTP, not %s", raw, u.Scheme)
		return
	}
	if u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		err = fmt.Errorf("invalid remote target '%s' — use HOST:PORT without a path", raw)
		return
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = strconv.Itoa(DefaultPort)
	}
	n, convErr := strconv.Atoi(port)
	if convErr != nil || n < 1 || n > 65535 {
		err = fmt.Errorf("invalid port '%s' in remote target '%s'", port, raw)
		return
	}
	// JoinHostPort brackets IPv6 hosts, so the address stays parseable.
	address = net.JoinHostPort(host, port)
	baseURL = "http://" + address
	return address, baseURL, nil
}

// NewConnection builds a client. The caller should call Verify before relying
// on it for writes.
func NewConnection(target, token string, readOnly bool) (*Connection, error) {
	address, baseURL, err := NormalizeTarget(target)
	if err != nil {
		return nil, err
	}
	return &Connection{
		Target:   strings.TrimSpace(target),
		Address:  address,
		BaseURL:  baseURL,
		Token:    strings.TrimSpace(token),
		ReadOnly: readOnly,
		client:   &http.Client{Timeout: 30 * time.Second},
		payloads: map[string][]byte{},
		etags:    map[string]string{},
		loaded:   map[string]bool{},
	}, nil
}

func (c *Connection) do(method, path, etag string, body []byte) ([]byte, string, int, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.BaseURL+path, reader)
	if err != nil {
		return nil, "", 0, err
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	if etag != "" {
		req.Header.Set("If-Match", etag)
	}
	res, err := c.client.Do(req)
	if err != nil {
		return nil, "", 0, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 200<<20))
	if err != nil {
		return nil, "", 0, err
	}
	next := res.Header.Get("ETag")
	if res.StatusCode == http.StatusNoContent {
		return nil, next, res.StatusCode, nil
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, next, res.StatusCode, decodeClientError(data, res.StatusCode)
	}
	return data, next, res.StatusCode, nil
}

func decodeClientError(data []byte, status int) error {
	var envelope struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(data, &envelope) == nil && envelope.Error != "" {
		return &ClientError{Status: status, Message: envelope.Error}
	}
	switch status {
	case http.StatusUnauthorized:
		return &ClientError{Status: status, Message: "the remote rejected the credentials — re-run 'dit connect' with the correct --token"}
	case http.StatusForbidden:
		return &ClientError{Status: status, Message: "the remote refused the write (it is running with --immutable)"}
	case http.StatusConflict:
		return &ClientError{Status: status, Message: "the remote changed since this command read it — re-run against the current data"}
	case http.StatusPreconditionFailed:
		return &ClientError{Status: status, Message: "the remote requires a precondition before a write — re-read the document and retry"}
	case http.StatusNotFound:
		return &ClientError{Status: status, Message: "the remote does not expose the dit protocol at this address"}
	default:
		return &ClientError{Status: status, Message: fmt.Sprintf("remote returned HTTP %d", status)}
	}
}

// Verify fetches the server's capability document.
func (c *Connection) Verify() (Info, error) {
	data, _, status, err := c.do(http.MethodGet, "/api/v1/info", "", nil)
	if err != nil {
		return Info{}, err
	}
	var info Info
	if err := json.Unmarshal(data, &info); err != nil || info.Schema != Schema {
		return Info{}, &ClientError{Status: status, Message: fmt.Sprintf(
			"%s is not a dit server (protocol mismatch) — is 'dit serve' running there?", c.Address)}
	}
	return info, nil
}

// Get fetches one document, caching it for the life of this connection.
func (c *Connection) Get(key string) ([]byte, string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.loaded[key] {
		return c.payloads[key], c.etags[key], nil
	}
	data, etag, _, err := c.do(http.MethodGet, "/api/v1/store/"+key, "", nil)
	if err != nil {
		return nil, "", err
	}
	c.payloads[key] = data
	c.etags[key] = etag
	c.loaded[key] = true
	return data, etag, nil
}

// Put replaces one document, using the ETag observed by Get. When this
// connection has never read the document, it reads it first so the write is
// still conditional: a dit client never blind-overwrites a remote document.
func (c *Connection) Put(key string, payload []byte) error {
	if err := c.ensureETag(key); err != nil {
		return err
	}
	c.mu.Lock()
	etag := c.etags[key]
	readOnly := c.ReadOnly
	c.mu.Unlock()
	if readOnly {
		return errors.New("the connection to " + c.Address + " is read-only; writes are refused")
	}
	_, _, _, err := c.do(http.MethodPut, "/api/v1/store/"+key, etag, payload)
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.payloads[key] = payload
	c.etags[key] = ETag(payload)
	c.loaded[key] = true
	c.mu.Unlock()
	return nil
}

// ensureETag guarantees the connection holds a current ETag for key, reading
// it when it has never been read: the server refuses writes without a
// precondition, so a blind write must condition itself first.
func (c *Connection) ensureETag(key string) error {
	c.mu.Lock()
	etag := c.etags[key]
	c.mu.Unlock()
	if etag != "" {
		return nil
	}
	_, err := c.getUncached(key)
	return err
}

// getUncached reads a document without consulting the cache, so a blind Put
// conditions itself against the server's current state, not a stale read.
func (c *Connection) getUncached(key string) (string, error) {
	data, etag, _, err := c.do(http.MethodGet, "/api/v1/store/"+key, "", nil)
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	c.payloads[key] = data
	c.etags[key] = etag
	c.loaded[key] = true
	c.mu.Unlock()
	return etag, nil
}

// PutDocuments replaces one or both documents atomically on the server.
// A nil payload leaves that document unchanged.
func (c *Connection) PutDocuments(portfolio, market []byte) error {
	c.mu.Lock()
	readOnly := c.ReadOnly
	c.mu.Unlock()
	if readOnly {
		return errors.New("the connection to " + c.Address + " is read-only; writes are refused")
	}
	// Every document being written needs a current precondition; the server
	// refuses a write that names none, and an absent document's precondition
	// is the "none" tag, so fetching is always possible.
	if portfolio != nil {
		if err := c.ensureETag(store.PortfolioKey); err != nil {
			return err
		}
	}
	if market != nil {
		if err := c.ensureETag(store.MarketKey); err != nil {
			return err
		}
	}
	c.mu.Lock()
	pEtag, mEtag := c.etags[store.PortfolioKey], c.etags[store.MarketKey]
	c.mu.Unlock()

	body := map[string]string{}
	if portfolio != nil {
		body["portfolio"] = string(portfolio)
		body["portfolioEtag"] = pEtag
	}
	if market != nil {
		body["market"] = string(market)
		body["marketEtag"] = mEtag
	}
	if len(body) == 0 {
		return nil
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	respBody, _, _, err := c.do(http.MethodPut, "/api/v1/documents", "", raw)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if portfolio != nil {
		c.payloads[store.PortfolioKey] = portfolio
		c.loaded[store.PortfolioKey] = true
	}
	if market != nil {
		c.payloads[store.MarketKey] = market
		c.loaded[store.MarketKey] = true
	}
	// The server returns the fresh per-document ETags for the pair; caching
	// them keeps the next write conditional against what was just committed,
	// without an extra round trip.
	var envelope struct {
		ETags map[string]string `json:"etags"`
	}
	if json.Unmarshal(respBody, &envelope) == nil {
		for key, etag := range envelope.ETags {
			c.etags[key] = etag
		}
	}
	c.mu.Unlock()
	return nil
}

// Bundle fetches the combined export document.
func (c *Connection) Bundle() ([]byte, error) {
	data, _, _, err := c.do(http.MethodGet, "/api/v1/bundle", "", nil)
	if err != nil {
		return nil, err
	}
	return data, nil
}

// VerifyUnchanged reports whether a document still matches original bytes.
// This is the network form of the changed-under-you guard.
func (c *Connection) VerifyUnchanged(key string, original []byte) error {
	req, err := http.NewRequest(http.MethodGet, c.BaseURL+"/api/v1/store/"+key, nil)
	if err != nil {
		return err
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	req.Header.Set("Cache-Control", "no-cache")
	res, err := c.client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 200<<20))
	if err != nil {
		return err
	}
	if res.StatusCode == http.StatusNoContent {
		data = nil
	} else if res.StatusCode != http.StatusOK {
		return decodeClientError(data, res.StatusCode)
	}
	if !bytes.Equal(data, original) {
		return fmt.Errorf("the remote %s changed since this command read it — nothing was replaced", key)
	}
	return nil
}

// ETag fingerprints a document; an absent document has the `none` tag.
func ETag(payload []byte) string {
	if payload == nil {
		return `"` + "none" + `"`
	}
	sum := sha256.Sum256(payload)
	return `"` + "sha256-" + hex.EncodeToString(sum[:]) + `"`
}

// Stores presents the remote endpoint as the ordinary store abstraction.
func (c *Connection) Stores() (store.Store, store.Store, error) {
	makeStore := func(key, label string) store.Store {
		return store.Store{
			Location: "remote://" + c.Address + "/" + key,
			Load: func(key string) ([]byte, error) {
				data, _, err := c.Get(key)
				return data, err
			},
			Save: func(key string, payload []byte) error {
				return c.Put(key, payload)
			},
			Delete: func(string) error {
				return fmt.Errorf("the remote store does not delete individual keys — documents are replaced")
			},
			Keys: func() ([]string, error) {
				return []string{key}, nil
			},
		}
	}
	ledger := makeStore(store.PortfolioKey, "portfolio")
	market := makeStore(store.MarketKey, "market data")
	return ledger, market, nil
}
