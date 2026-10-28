package run

import (
	"reflect"
	"strings"
	"testing"
)

// gitDiff is git diff output with a change, a new file, a rename, a deleted
// file, and a binary file.
const gitDiff = `diff --git a/search/match.go b/search/match.go
index 1111111..2222222 100644
--- a/search/match.go
+++ b/search/match.go
@@ -18,4 +18,5 @@ func Match(q string) []Result {
 	var out []Result
-	if score == 0 {
+	if score == 0 && kind == link {
+		score = label
 	}
 	return out
\ No newline at end of file
diff --git a/docs/new file.md b/docs/new file.md
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/docs/new file.md
@@ -0,0 +1,2 @@
+# New
+Text.
diff --git a/old.go b/new.go
similarity index 90%
rename from old.go
rename to new.go
index 4444444..5555555 100644
--- a/old.go
+++ b/new.go
@@ -1 +1 @@
-package old
+package new
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 6666666..0000000
--- a/gone.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/logo.png b/logo.png
new file mode 100644
index 0000000..7777777
Binary files /dev/null and b/logo.png differ
`

func TestParseDiff(t *testing.T) {
	files := parseDiff(gitDiff, 100)
	if len(files) != 5 {
		t.Fatalf("%d files: %+v", len(files), files)
	}
	match := files[0]
	want := DiffFile{Path: "search/match.go", Status: "modified", Added: 2, Deleted: 1, Hunks: []DiffHunk{{
		Header: "@@ -18,4 +18,5 @@ func Match(q string) []Result {", OldStart: 18, NewStart: 18,
		Lines: []DiffLine{
			{Kind: "context", Old: 18, New: 18, Text: "\tvar out []Result"},
			{Kind: "del", Old: 19, Text: "\tif score == 0 {"},
			{Kind: "add", New: 19, Text: "\tif score == 0 && kind == link {"},
			{Kind: "add", New: 20, Text: "\t\tscore = label"},
			{Kind: "context", Old: 20, New: 21, Text: "\t}"},
			{Kind: "context", Old: 21, New: 22, Text: "\treturn out"},
		},
	}}}
	if !reflect.DeepEqual(match, want) {
		t.Errorf("modified:\n got %+v\nwant %+v", match, want)
	}
	if f := files[1]; f.Path != "docs/new file.md" || f.Status != "added" || f.Added != 2 || f.Hunks[0].Lines[1].New != 2 {
		t.Errorf("added: %+v", f)
	}
	if f := files[2]; f.Path != "new.go" || f.OldPath != "old.go" || f.Status != "renamed" || f.Added != 1 || f.Deleted != 1 {
		t.Errorf("renamed: %+v", f)
	}
	if f := files[3]; f.Path != "gone.txt" || f.Status != "deleted" || f.Deleted != 1 {
		t.Errorf("deleted: %+v", f)
	}
	if f := files[4]; f.Path != "logo.png" || f.Status != "added" || !f.Binary || len(f.Hunks) != 0 {
		t.Errorf("binary: %+v", f)
	}
}

func TestParseDiffCutsALongFile(t *testing.T) {
	var b strings.Builder
	b.WriteString("diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,10 @@\n")
	for range 10 {
		b.WriteString("+line\n")
	}
	f := parseDiff(b.String(), 4)[0]
	if !f.Truncated || len(f.Hunks[0].Lines) != 4 || f.Added != 10 {
		t.Fatalf("%+v", f)
	}
}
