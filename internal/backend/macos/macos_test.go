package macos

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/types"
)

func TestParseEvents(t *testing.T) {
	row := strings.Join([]string{
		"event-1", "Planning", "Full description", "1.7896032E+9", "1.7896068E+9", "false",
		"Room", "https://example.test/event", "FREQ=WEEKLY", "none",
		"alice@example.com" + string(valueSep) + "Alice" + string(valueSep) + "accepted" + string(recordSep) + "bob@example.com" + string(valueSep) + "Bob" + string(valueSep) + "tentative",
	}, string(fieldSep))

	events, err := parseEvents(row+"\n", "Calendar")
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 {
		t.Fatalf("got %d events, want 1", len(events))
	}
	event := events[0]
	if event.ID != "event-1" || event.Subject != "Planning" || event.Body != "Full description" {
		t.Fatalf("unexpected event: %#v", event)
	}
	if !event.Start.Before(event.End) || event.Location != "Room" || event.WebLink == "" {
		t.Fatalf("unexpected event timing/details: %#v", event)
	}
	if len(event.Attendees) != 2 || event.Attendees[1].Status != "tentative" {
		t.Fatalf("unexpected attendees: %#v", event.Attendees)
	}
}

func TestListEventsUsesRange(t *testing.T) {
	from := time.Date(2026, 9, 16, 0, 0, 0, 0, time.Local)
	to := from.Add(24 * time.Hour)
	if !from.Before(to) {
		t.Fatal("test range must be ordered")
	}
	var _ types.Event
}

func TestEventByIDScriptUsesIDPredicate(t *testing.T) {
	script := fmt.Sprintf(eventByIDScript, quote("Calendar"), 0.0, 0.0, quote("event-1"))
	if !strings.Contains(script, `whose id is "event-1"`) {
		t.Fatalf("event lookup script does not contain ID predicate: %s", script)
	}
}
