package mcpserver

import (
	"context"
	"testing"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/types"
)

type fakeBackend struct{}

func (fakeBackend) ListCalendars(context.Context) ([]types.Calendar, error) {
	return []types.Calendar{{ID: "calendar", Name: "Calendar"}}, nil
}

func (fakeBackend) ListEvents(context.Context, time.Time, time.Time) ([]types.Event, error) {
	return []types.Event{}, nil
}

func (fakeBackend) GetEvent(context.Context, string) (*types.Event, error) {
	return nil, nil
}

func (fakeBackend) GetFreeBusy(context.Context, []string, time.Time, time.Time) ([]types.FreeBusyResult, error) {
	return []types.FreeBusyResult{}, nil
}

func TestParseRangeDefaultsToOneDay(t *testing.T) {
	before := time.Now()
	from, to, err := parseRange("", "")
	if err != nil {
		t.Fatal(err)
	}
	if from.Before(before.Add(-time.Second)) || to.Sub(from) != 24*time.Hour {
		t.Fatalf("unexpected default range: %s to %s", from, to)
	}
}

func TestParseRangeRejectsInvertedRange(t *testing.T) {
	_, _, err := parseRange("2026-09-17T00:00:00Z", "2026-09-16T00:00:00Z")
	if err == nil {
		t.Fatal("expected inverted range to fail")
	}
}

func TestMCPBuildsReadOnlyCalendarServer(t *testing.T) {
	server := New(fakeBackend{}).MCP()
	if server == nil {
		t.Fatal("expected MCP server")
	}
}
