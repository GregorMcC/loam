package run

import (
	"testing"

	"github.com/GregorMcC/loam/core/internal/store"
)

// The host of the link says the kind of the source, not a text in its path.
func TestSourceOfReadsTheKindFromTheHost(t *testing.T) {
	cases := map[string]struct {
		link store.WorktreeLink
		want string
	}{
		"linear issue":          {store.WorktreeLink{Target: "https://linear.app/acme/issue/ENG-523/rename-the-setting", Key: "ENG-523"}, "linear"},
		"github issue":          {store.WorktreeLink{Target: "https://github.com/example/widgets/issues/57", Key: "#57"}, "github"},
		"linear.app in a path":  {store.WorktreeLink{Target: "https://github.com/acme/linear.app/issues/3", Key: "acme/linear.app#3"}, "github"},
		"linear.app in a query": {store.WorktreeLink{Target: "https://github.com/example/widgets/issues/4?from=linear.app/acme", Key: "#4"}, "github"},
	}
	for name, c := range cases {
		got := sourceOf(&c.link)
		if got == nil {
			t.Fatalf("%s: no source", name)
		}
		if got.Kind != c.want || got.Key != c.link.Key || got.URL != c.link.Target {
			t.Errorf("%s: got %+v, want kind %q, key %q, URL %q", name, *got, c.want, c.link.Key, c.link.Target)
		}
	}
}

// A link without a key is not an issue, so it gives no source.
func TestSourceOfALinkWithoutAKey(t *testing.T) {
	if got := sourceOf(&store.WorktreeLink{Target: "https://linear.app/acme/issue/ENG-523"}); got != nil {
		t.Errorf("got %+v, want no source", *got)
	}
	if got := sourceOf(nil); got != nil {
		t.Errorf("got %+v for no link, want no source", *got)
	}
}
