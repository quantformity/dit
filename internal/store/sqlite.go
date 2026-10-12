package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	_ "modernc.org/sqlite"
)

// NewSQLiteStore builds the SQLite backend over one database file.
//
// It creates the same table the Swift implementation creates, so a portfolio
// moved between the two binaries does not have to be dumped and reloaded: the
// database file itself is the interchange. Payloads are stored as BLOB, not
// TEXT, matching Swift byte for byte.
//
// Concurrency: one connection, because the SQLite file is not the place where
// the tool serializes work. A second connection would only invite "database is
// locked" in a command-line program that never wants two writers.
func NewSQLiteStore(path string) (Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return Store{}, &Error{Key: "<open>", Message: fmt.Sprintf("cannot create %s: %v",
			filepath.Dir(path), err)}
	}
	database, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return Store{}, &Error{Key: "<open>", Message: err.Error()}
	}
	database.SetMaxOpenConns(1)
	if err := database.Ping(); err != nil {
		database.Close()
		return Store{}, &Error{Key: "<open>", Message: err.Error()}
	}
	if _, err := database.Exec(
		"CREATE TABLE IF NOT EXISTS store (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"); err != nil {
		database.Close()
		return Store{}, &Error{Key: "<init>", Message: "schema creation failed: " + err.Error()}
	}

	return Store{
		Location: path,
		Load: func(key string) ([]byte, error) {
			var payload []byte
			err := database.QueryRow("SELECT payload FROM store WHERE key = ?", key).Scan(&payload)
			switch {
			case err == sql.ErrNoRows:
				return nil, nil
			case err != nil:
				return nil, &Error{Key: key, Message: err.Error()}
			}
			return payload, nil
		},
		Save: func(key string, payload []byte) error {
			_, err := database.Exec(
				"INSERT INTO store (key, payload) VALUES (?, ?) "+
					"ON CONFLICT(key) DO UPDATE SET payload = excluded.payload", key, payload)
			if err != nil {
				return &Error{Key: key, Message: err.Error()}
			}
			return nil
		},
		Delete: func(key string) error {
			if _, err := database.Exec("DELETE FROM store WHERE key = ?", key); err != nil {
				return &Error{Key: key, Message: err.Error()}
			}
			return nil
		},
		Keys: func() ([]string, error) {
			rows, err := database.Query("SELECT key FROM store ORDER BY key")
			if err != nil {
				return nil, &Error{Key: "<keys>", Message: err.Error()}
			}
			defer rows.Close()
			keys := []string{}
			for rows.Next() {
				var key string
				if err := rows.Scan(&key); err != nil {
					return nil, &Error{Key: "<keys>", Message: err.Error()}
				}
				keys = append(keys, key)
			}
			return keys, rows.Err()
		},
	}, nil
}

// SplitPairKey recovers a pair from a storage key, used by the FX lookups that
// key a series by "USD/CAD". Kept here because it is a storage question: the
// key had to be flattened into a filename or a row name somewhere.
func SplitPairKey(key string) (base, quote string, ok bool) {
	parts := strings.SplitN(key, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}
