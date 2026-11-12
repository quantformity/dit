package config

import (
	"path/filepath"
	"strings"
)

// RemoteConnection is the saved `dit connect` state. The URL is conventionally
// a `host:port` address; the client adds the HTTP scheme.
type RemoteConnection struct {
	URL      string
	Token    string
	ReadOnly bool
}

// LoadRemoteConnection reads the active connection, if any. A missing config
// is not an error: “not connected” is the normal state.
func LoadRemoteConnection() (RemoteConnection, error) {
	cfg, err := loadOrCreateUserConfig()
	if err != nil {
		return RemoteConnection{}, err
	}
	return RemoteConnection{
		URL:      strings.TrimSpace(cfg.RemoteURL),
		Token:    strings.TrimSpace(cfg.RemoteToken),
		ReadOnly: strings.EqualFold(strings.TrimSpace(cfg.RemoteReadOnly), "true"),
	}, nil
}

// SaveRemoteConnection records (or replaces) the active connection.
func SaveRemoteConnection(connection RemoteConnection) error {
	cfg, err := loadOrCreateUserConfig()
	if err != nil {
		return err
	}
	cfg.RemoteURL = strings.TrimSpace(connection.URL)
	cfg.RemoteToken = strings.TrimSpace(connection.Token)
	if connection.ReadOnly {
		cfg.RemoteReadOnly = "true"
	} else {
		cfg.RemoteReadOnly = ""
	}
	return writeUserConfig(cfg)
}

// ClearRemoteConnection removes the saved connection.
func ClearRemoteConnection() error {
	cfg, err := loadOrCreateUserConfig()
	if err != nil {
		return err
	}
	cfg.RemoteURL = ""
	cfg.RemoteToken = ""
	cfg.RemoteReadOnly = ""
	return writeUserConfig(cfg)
}

// RemoteConfigPath exposes where the connection state lives, for help text.
func RemoteConfigPath() string {
	return filepath.Join(homeDirectory(), ".dit", configFileName)
}
