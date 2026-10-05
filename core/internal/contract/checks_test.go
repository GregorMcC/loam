package contract

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/GregorMcC/loam/core/internal/session"
	"github.com/google/jsonschema-go/jsonschema"
)

func readFile(t *testing.T, parts ...string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(append([]string{contractDir}, parts...)...))
	if err != nil {
		t.Fatalf("%v\nRun the test with -update to make the fixtures.", err)
	}
	return b
}

// loadSchema reads contract/schema/<name>.json and resolves its references.
func loadSchema(t *testing.T, name string) *jsonschema.Resolved {
	t.Helper()
	dir := filepath.Join(contractDir, "schema")
	load := func(file string) (*jsonschema.Schema, error) {
		b, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			return nil, err
		}
		var s jsonschema.Schema
		if err := json.Unmarshal(b, &s); err != nil {
			return nil, fmt.Errorf("%s: %w", file, err)
		}
		return &s, nil
	}
	root, err := load(name + ".json")
	if err != nil {
		t.Fatal(err)
	}
	rs, err := root.Resolve(&jsonschema.ResolveOptions{
		BaseURI: "https://loam.invalid/schema/" + name + ".json",
		Loader: func(u *url.URL) (*jsonschema.Schema, error) {
			return load(filepath.Base(u.Path))
		},
	})
	if err != nil {
		t.Fatalf("schema %s: %v", name, err)
	}
	return rs
}

func validate(t *testing.T, schema, what string, doc []byte) {
	t.Helper()
	var v any
	if err := json.Unmarshal(doc, &v); err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	if err := loadSchema(t, schema).Validate(v); err != nil {
		t.Errorf("%s does not match schema %s.json: %v", what, schema, err)
	}
}

// shape describes the keys and the JSON types of a value, not the values.
func shape(v any) string {
	switch x := v.(type) {
	case map[string]any:
		ks := make([]string, 0, len(x))
		for k := range x {
			ks = append(ks, k)
		}
		sort.Strings(ks)
		parts := make([]string, len(ks))
		for i, k := range ks {
			parts[i] = fmt.Sprintf("%q:%s", k, shape(x[k]))
		}
		return "{" + strings.Join(parts, ",") + "}"
	case []any:
		seen := map[string]bool{}
		for _, e := range x {
			seen[shape(e)] = true
		}
		return "[" + strings.Join(keys(seen), "|") + "]"
	case nil:
		return "null"
	case string:
		return "string"
	case float64:
		return "number"
	case bool:
		return "bool"
	}
	return fmt.Sprintf("%T", v)
}

func shapeOf(t *testing.T, doc []byte) string {
	t.Helper()
	var v any
	if err := json.Unmarshal(doc, &v); err != nil {
		t.Fatal(err)
	}
	return shape(v)
}

func manifestJSON(t *testing.T, entries []Entry) []byte {
	t.Helper()
	b, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}

func keys(m map[string]bool) []string {
	var ks []string
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

func TestContractFixtures(t *testing.T) {
	h := scenario(t)
	fixtures := filepath.Join(contractDir, "fixtures")
	if updating() {
		if err := os.RemoveAll(fixtures); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(fixtures, 0o755); err != nil {
			t.Fatal(err)
		}
		for name, b := range h.outputs {
			if err := os.WriteFile(filepath.Join(fixtures, name+".json"), b, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(fixtures, "manifest.json"), manifestJSON(t, h.entries), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// The manifest must match what the scenario ran.
	if got, want := readFile(t, "fixtures", "manifest.json"), manifestJSON(t, h.entries); !bytes.Equal(got, want) {
		t.Errorf("fixtures/manifest.json differs from the commands the test ran. Run with -update.\nfile:\n%s\nran:\n%s", got, want)
	}
	for _, e := range h.entries {
		live := h.outputs[e.Name]
		validate(t, e.Schema, "output of "+e.Name, live)
		fixture := readFile(t, "fixtures", e.Name+".json")
		validate(t, e.Schema, "fixture "+e.Name, fixture)
		if a, b := shapeOf(t, live), shapeOf(t, fixture); a != b {
			t.Errorf("%s: the output shape differs from the fixture. Run with -update if the change is on purpose.\noutput:  %s\nfixture: %s", e.Name, a, b)
		}
	}
}

func readEntries(t *testing.T) []Entry {
	t.Helper()
	var es []Entry
	if err := json.Unmarshal(readFile(t, "fixtures", "manifest.json"), &es); err != nil {
		t.Fatal(err)
	}
	return es
}

var cmdRE = regexp.MustCompile("`(loam [^`]+)`")

// commandPath returns the command words of "loam link add <plot> [--note]".
func commandPath(s string) string {
	var words []string
	for _, w := range strings.Fields(strings.TrimPrefix(s, "loam ")) {
		if strings.HasPrefix(w, "<") || strings.HasPrefix(w, "[") || strings.HasPrefix(w, "-") {
			break
		}
		words = append(words, w)
	}
	return strings.Join(words, " ")
}

// runPaths returns the command words of a run: the first word, and the first
// two words (for "link add").
func runPaths(args []string) []string {
	var words []string
	for _, a := range args {
		if strings.HasPrefix(a, "-") || len(words) == 2 {
			break
		}
		words = append(words, a)
	}
	out := []string{words[0]}
	if len(words) == 2 {
		out = append(out, strings.Join(words, " "))
	}
	return out
}

func TestContractCoversDocs(t *testing.T) {
	doc := string(readFile(t, "..", "docs", "contract.md"))
	entries := readEntries(t)
	ran := map[string]bool{}
	for _, e := range entries {
		for _, p := range runPaths(e.Args) {
			ran[p] = true
		}
	}
	// Every command in the sections before "Commands without JSON output" has
	// a fixture.
	jsonPart, _, ok := strings.Cut(doc, "### Commands without JSON output")
	if !ok {
		t.Fatal("docs/contract.md has no section 'Commands without JSON output'")
	}
	_, jsonPart, _ = strings.Cut(jsonPart, "## Commands")
	n := 0
	for _, m := range cmdRE.FindAllStringSubmatch(jsonPart, -1) {
		n++
		if p := commandPath(m[1]); !ran[p] {
			t.Errorf("docs/contract.md names `%s`, and no fixture runs %q", m[1], p)
		}
	}
	if n < 20 {
		t.Errorf("found only %d commands in docs/contract.md: the parser may be wrong", n)
	}
	// Every exit code in the table has an error fixture, except the codes that
	// the table says the core does not return today. Every error fixture has a
	// code in the table.
	notReturned := map[string]bool{"contract_mismatch": true}
	kinds, codes := map[string]bool{}, map[int]string{}
	for _, e := range entries {
		if e.ExitCode == 0 {
			continue
		}
		var v struct {
			Error struct {
				Kind     string `json:"kind"`
				ExitCode int    `json:"exit_code"`
			} `json:"error"`
		}
		if err := json.Unmarshal(readFile(t, "fixtures", e.Name+".json"), &v); err != nil {
			t.Fatal(err)
		}
		if v.Error.ExitCode != e.ExitCode {
			t.Errorf("fixture %s: exit_code %d in the JSON, %d for the process", e.Name, v.Error.ExitCode, e.ExitCode)
		}
		kinds[v.Error.Kind] = true
		codes[e.ExitCode] = v.Error.Kind
	}
	rows := regexp.MustCompile("(?m)^\\| (\\d+) \\| `(\\w+)` \\|").FindAllStringSubmatch(doc, -1)
	if len(rows) == 0 {
		t.Fatal("docs/contract.md has no exit code table")
	}
	table := map[string]string{}
	for _, r := range rows {
		table[r[1]] = r[2]
		if !kinds[r[2]] && !notReturned[r[2]] {
			t.Errorf("docs/contract.md lists exit code %s (%s), and no fixture has it", r[1], r[2])
		}
	}
	for code, kind := range codes {
		if table[fmt.Sprint(code)] != kind {
			t.Errorf("a fixture has exit code %d with kind %q, and docs/contract.md says %q", code, kind, table[fmt.Sprint(code)])
		}
	}
}

func TestContractFilesMatch(t *testing.T) {
	entries := readEntries(t)
	schemas, fixtures := map[string]bool{"defs": true}, map[string]bool{"manifest": true}
	for _, e := range entries {
		schemas[e.Schema] = true
		fixtures[e.Name] = true
	}
	list := func(dir string) map[string]bool {
		fs, err := os.ReadDir(filepath.Join(contractDir, dir))
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]bool{}
		for _, f := range fs {
			m[strings.TrimSuffix(f.Name(), ".json")] = true
		}
		return m
	}
	if got := list("schema"); !reflect.DeepEqual(got, schemas) {
		t.Errorf("schema files %v do not match the schemas that the manifest uses %v", keys(got), keys(schemas))
	}
	if got := list("fixtures"); !reflect.DeepEqual(got, fixtures) {
		t.Errorf("fixture files %v do not match the manifest %v", keys(got), keys(fixtures))
	}
}

// The event table in the code, the schema, and "Pane socket" in the docs name
// the same events.
func TestContractPaneEvents(t *testing.T) {
	var schema struct {
		Properties struct {
			Event struct {
				Enum []string `json:"enum"`
			} `json:"event"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(readFile(t, "schema", "pane-event.json"), &schema); err != nil {
		t.Fatal(err)
	}
	want := session.PaneEvents()
	sort.Strings(want)
	got := append([]string{}, schema.Properties.Event.Enum...)
	sort.Strings(got)
	if !reflect.DeepEqual(got, want) {
		t.Errorf("schema/pane-event.json lists events %v, and the event table in the code has %v", got, want)
	}
	doc := string(readFile(t, "..", "docs", "contract.md"))
	_, section, ok := strings.Cut(doc, "\n## Pane socket\n")
	if !ok {
		t.Fatal("docs/contract.md has no section 'Pane socket'")
	}
	for _, ev := range want {
		if !strings.Contains(section, "| `"+ev+"` |") {
			t.Errorf("'Pane socket' in docs/contract.md has no row for %s", ev)
		}
	}
}
