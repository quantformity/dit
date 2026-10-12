// Package store is the persistence layer.
//
// A store is a VALUE built by a function, not an object with behaviour: the
// four operations a backend must provide are plain function fields, and
// choosing file vs SQLite is choosing how to build one. That keeps the choice
// where it belongs — at the edge, in main — and leaves everything above it
// working on data.
//
// Both backends hold the same JSON payloads. The SQLite one keeps them in
// "store (key TEXT PRIMARY KEY, payload BLOB)", the same table the Swift
// implementation creates, so a database written by either binary is readable
// by the other.
package store

import "fmt"

// Store is a key/value byte store.
//
// Load must return (nil, nil) for an absent key: "nothing recorded" and "I
// could not look" are different answers, and collapsing them is how an empty
// report gets printed over a broken store.
type Store struct {
	// Location describes where the data lives, for "store path".
	Location string
	// Load returns the payload for a key, or nil when there is none.
	Load func(key string) ([]byte, error)
	// Save replaces the payload atomically.
	Save func(key string, payload []byte) error
	// Delete removes a key; deleting something absent is a no-op.
	Delete func(key string) error
	// Keys lists the recoverable keys, sorted.
	Keys func() ([]string, error)
}

// Error is a storage failure. It carries the key so a message can name what
// could not be read; a report that says only "I/O error" sends the user to
// guess which of their two stores is broken.
type Error struct {
	Key     string
	Message string
}

func (e *Error) Error() string {
	return fmt.Sprintf("store error at %s: %s", e.Key, e.Message)
}

// KeysOrEmpty is the lenient read used for display: a store we cannot list is
// reported as having no keys rather than failing the whole command, because
// the listing is decoration while the document above it is the answer.
func (s Store) KeysOrEmpty() []string {
	keys, err := s.Keys()
	if err != nil || keys == nil {
		return []string{}
	}
	return keys
}
