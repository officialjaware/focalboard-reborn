// Copyright (c) 2015-present Mattermost, Inc. All Rights Reserved.
// See LICENSE.txt for license information.

package sqlstore

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRetrieveFileIDFromBlockFieldStorage(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "empty string does not panic",
			input:    "",
			expected: "",
		},
		{
			name:     "standard file id with extension",
			input:    "!abc123.png",
			expected: "abc123",
		},
		{
			name:     "file id without extension",
			input:    "!abc123",
			expected: "abc123",
		},
		{
			name:     "just the prefix character",
			input:    "!",
			expected: "",
		},
		{
			name:     "malformed: no prefix character",
			input:    "abc123.png",
			expected: "bc123",
		},
		{
			name:     "file id with multiple dots",
			input:    "!abc123.tar.gz",
			expected: "abc123",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			require.NotPanics(t, func() {
				result := retrieveFileIDFromBlockFieldStorage(tc.input)
				require.Equal(t, tc.expected, result)
			})
		})
	}
}
