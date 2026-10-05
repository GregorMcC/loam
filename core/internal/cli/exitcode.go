package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"

	"github.com/GregorMcC/loam/core/internal/store"
)

// The exit codes of loam. They are stable: the app reads them. Add a code at
// the end of its range and document it in docs/contract.md.
const (
	ExitOK               = 0
	ExitError            = 1  // any error that has no code of its own
	ExitInvalid          = 2  // bad flag, argument, or value
	ExitStale            = 10 // a write used a version that is out of date
	ExitUndoClash        = 11 // an undo meets a later change to the same item
	ExitLinkPathMissing  = 12 // a local link points at a path that does not exist
	ExitContractMismatch = 13 // the caller expects another contract version
	ExitUnknownPlot      = 14 // no plot matches the argument
	ExitAmbiguous        = 15 // the argument matches more than one plot or link
)

// Errors that map to an exit code. Wrap them with %w. A later ticket that
// builds the matching command returns them.
var (
	// ErrUndoClash means an undo meets a later change. An error that wraps it
	// can add the later changes with an ErrorDetails method.
	ErrUndoClash = errors.New("undo clash")
	// ErrLinkPathMissing means a local link target does not exist.
	ErrLinkPathMissing = errors.New("link path missing")
	// ErrContractMismatch means the contract version is not the one expected.
	ErrContractMismatch = errors.New("contract version mismatch")
	// ErrUnknownPlot means no plot matches. It also matches store.ErrNotFound.
	ErrUnknownPlot = errors.New("unknown plot")
)

// unknownPlotError is the error of a plot argument that matches no plot.
type unknownPlotError struct{ arg string }

func (e unknownPlotError) Error() string { return fmt.Sprintf("no plot matches %q", e.arg) }
func (e unknownPlotError) Is(target error) bool {
	return target == ErrUnknownPlot || target == store.ErrNotFound
}

// usageError marks a bad command line (flags, argument count, unknown command).
type usageError struct{ err error }

func (u usageError) Error() string        { return u.err.Error() }
func (u usageError) Unwrap() error        { return u.err }
func (u usageError) Is(target error) bool { return target == store.ErrInvalid }

// detailer is implemented by errors that carry data for the JSON error.
type detailer interface{ ErrorDetails() any }

// ErrorBody is the "error" object of the JSON error shape.
type ErrorBody struct {
	// Kind is a stable name for the exit code.
	Kind     string `json:"kind"`
	ExitCode int    `json:"exit_code"`
	Message  string `json:"message"`
	// Details depends on Kind. A stale write holds the plot ID and the stale
	// items with their current values.
	Details any `json:"details,omitempty"`
}

// classify maps an error to its exit code, kind, and details.
func classify(err error) ErrorBody {
	b := ErrorBody{Kind: "error", ExitCode: ExitError, Message: err.Error()}
	var se *store.StaleError
	var d detailer
	switch {
	case errors.As(err, &se):
		b.Kind, b.ExitCode, b.Details = "stale", ExitStale, se
	case errors.Is(err, ErrUndoClash):
		b.Kind, b.ExitCode = "undo_clash", ExitUndoClash
	case errors.Is(err, ErrLinkPathMissing):
		b.Kind, b.ExitCode = "link_path_missing", ExitLinkPathMissing
	case errors.Is(err, ErrContractMismatch):
		b.Kind, b.ExitCode = "contract_mismatch", ExitContractMismatch
	case errors.Is(err, ErrAmbiguous):
		b.Kind, b.ExitCode = "ambiguous", ExitAmbiguous
	case errors.Is(err, ErrUnknownPlot):
		b.Kind, b.ExitCode = "unknown_plot", ExitUnknownPlot
	case errors.Is(err, store.ErrInvalid):
		b.Kind, b.ExitCode = "invalid", ExitInvalid
	}
	if b.Details == nil && errors.As(err, &d) {
		b.Details = d.ErrorDetails()
	}
	return b
}

// writeError reports err and returns its exit code. With asJSON it prints
// {"error": {...}} as one JSON document on stdout and nothing on stderr.
// Otherwise it prints one line on stderr.
func writeError(out, errOut io.Writer, err error, asJSON bool) int {
	b := classify(err)
	if asJSON {
		enc := json.NewEncoder(out)
		enc.SetIndent("", "  ")
		_ = enc.Encode(struct {
			Error ErrorBody `json:"error"`
		}{b})
	} else {
		fmt.Fprintln(errOut, "loam:", err)
	}
	return b.ExitCode
}
