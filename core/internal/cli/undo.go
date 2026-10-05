package cli

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/GregorMcC/loam/core/internal/seed"
	"github.com/GregorMcC/loam/core/internal/store"
	"github.com/spf13/cobra"
)

func init() {
	Register(newUndoCmd)
	Register(newChangesCmd)
}

// undoClashError wraps the store clash so that it maps to exit code 11 and
// carries the later changes in the JSON error details.
type undoClashError struct{ err *store.UndoClashError }

func (e undoClashError) Error() string        { return e.err.Error() }
func (e undoClashError) Unwrap() error        { return e.err }
func (e undoClashError) Is(target error) bool { return target == ErrUndoClash }

// ErrorDetails returns the store clash: the later changes and what the undo
// would write.
func (e undoClashError) ErrorDetails() any { return e.err }

func newUndoCmd() *cobra.Command {
	var overwrite bool
	c := &cobra.Command{
		Use:   "undo <change-id> [--overwrite]",
		Short: "Undo a change to a plot",
		Long: "Undo a change. Undo writes the old values back as a new change. The change log keeps every entry.\n" +
			"If a later change edited the same item, nothing is written. On a terminal, the command shows the later changes and asks.\n" +
			"With --json, or with no terminal, it exits with code 11 and returns the later changes. Use --overwrite to write anyway.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := strconv.ParseInt(args[0], 10, 64)
			if err != nil || id < 1 {
				return fmt.Errorf("%q is not a change ID: %w", args[0], store.ErrInvalid)
			}
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			return runUndo(cmd, s, id, overwrite)
		},
	}
	c.Flags().BoolVar(&overwrite, "overwrite", false, "write the old values even if a later change edited the same items")
	return c
}

func runUndo(cmd *cobra.Command, s *store.Store, id int64, overwrite bool) error {
	res, err := s.Undo(id, cliActor(cmd), overwrite)
	var ce *store.UndoClashError
	if errors.As(err, &ce) {
		if JSON(cmd) || !stdinIsTerminal(cmd.InOrStdin()) {
			return undoClashError{ce}
		}
		showClash(cmd.OutOrStdout(), ce)
		fmt.Fprint(cmd.OutOrStdout(), "Overwrite? [y/N] ")
		line, _ := bufio.NewReader(cmd.InOrStdin()).ReadString('\n')
		if a := strings.ToLower(strings.TrimSpace(line)); a != "y" && a != "yes" {
			return errors.New("nothing was changed")
		}
		res, err = s.Undo(id, cliActor(cmd), true)
	}
	if err != nil {
		return err
	}
	seed.AfterChange(s, res)
	printWarnings(cmd, res.Warnings)
	if JSON(cmd) {
		return printJSON(cmd, struct {
			ChangeID int64  `json:"change_id"`
			Undone   int64  `json:"undone"`
			Plot     string `json:"plot"`
		}{res.ChangeID, id, res.Plot.ID})
	}
	if res.ChangeID == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No change.")
		return nil
	}
	fmt.Fprintf(cmd.OutOrStdout(), "Undid change %d as change %d.\n", id, res.ChangeID)
	return nil
}

func showClash(out io.Writer, ce *store.UndoClashError) {
	fmt.Fprintf(out, "Later changes edited the same items as change %d:\n", ce.ChangeID)
	for _, c := range ce.Later {
		writeChange(out, c)
	}
	fmt.Fprintln(out, "Undo would write:")
	for _, e := range ce.Writes {
		fmt.Fprintf(out, "    %s %s: %s -> %s\n", e.Item, e.Field, shortVal(e.Old), shortVal(e.New))
	}
}

func newChangesCmd() *cobra.Command {
	var since int64
	c := &cobra.Command{
		Use:   "changes [<plot>] [--since <id>]",
		Short: "Show the change log",
		Long: "Show the change log, newest last. Each change has an actor, a time, and the old and new value of each field.\n" +
			"Without a plot, it shows every plot. --since shows only changes with an ID above the given ID.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			s, err := openStore()
			if err != nil {
				return err
			}
			defer s.Close()
			q := store.ChangeQuery{SinceID: since}
			if len(args) == 1 {
				ps, err := resolvePlot(s, args[0])
				if err != nil {
					return err
				}
				q.PlotID = ps.ID
			}
			cs, err := s.ListChanges(q)
			if err != nil {
				return err
			}
			if JSON(cmd) {
				return printJSON(cmd, struct {
					Changes []store.ChangeRecord `json:"changes"`
				}{cs})
			}
			if len(cs) == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "No changes.")
			}
			for _, c := range cs {
				writeChange(cmd.OutOrStdout(), c)
			}
			return nil
		},
	}
	c.Flags().Int64Var(&since, "since", 0, "show only changes with an ID above this")
	return c
}

func actorLabel(a store.Actor) string {
	switch a.Kind {
	case store.ActorApp:
		return "you (app)"
	case store.ActorCLI:
		return "you (cli)"
	}
	id := a.SessionID
	if len(id) > 6 {
		id = id[:6]
	}
	l := strings.TrimSpace("claude " + id)
	if !a.LoamStarted {
		l += " (outside Loam)"
	}
	return l
}

func shortVal(v *string) string {
	if v == nil {
		return "(none)"
	}
	s := strings.Join(strings.Fields(*v), " ")
	if r := []rune(s); len(r) > 60 {
		s = string(r[:57]) + "..."
	}
	return strconv.Quote(s)
}

func writeChange(out io.Writer, c store.ChangeRecord) {
	fmt.Fprintf(out, "%d  %s  %s  plot %s\n", c.ID, c.At.Format("2006-01-02 15:04:05"), actorLabel(c.Actor), c.PlotID)
	for _, e := range c.Entries {
		fmt.Fprintf(out, "    %s %s: %s -> %s\n", e.Item, e.Field, shortVal(e.Old), shortVal(e.New))
	}
}
