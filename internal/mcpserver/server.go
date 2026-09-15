package mcpserver

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/backend"
	"github.com/lucymhdavies/outlook-calendar/internal/types"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type Server struct {
	backend backend.Backend
}

func New(calendarBackend backend.Backend) *Server {
	return &Server{backend: calendarBackend}
}

func (server *Server) MCP() *mcp.Server {
	mcpServer := mcp.NewServer(&mcp.Implementation{
		Name:        "outlook-calendar",
		Title:       "Outlook Calendar",
		Version:     "0.1.0",
		Description: "Read-only access to calendars synced into macOS Calendar.",
	}, nil)

	mcp.AddTool(mcpServer, &mcp.Tool{
		Name:        "list_calendars",
		Description: "List calendars available through the local macOS Calendar account.",
	}, server.listCalendars)
	mcp.AddTool(mcpServer, &mcp.Tool{
		Name:        "list_events",
		Description: "List calendar events overlapping a time range. Defaults to the next 24 hours.",
	}, server.listEvents)
	mcp.AddTool(mcpServer, &mcp.Tool{
		Name:        "get_event",
		Description: "Get a calendar event by its Calendar.app event ID, including its full description and attendees.",
	}, server.getEvent)
	mcp.AddTool(mcpServer, &mcp.Tool{
		Name:        "get_freebusy",
		Description: "Return busy slots derived from the local calendar. This does not query other people's availability.",
	}, server.getFreeBusy)
	return mcpServer
}

type listEventsInput struct {
	From  string `json:"from,omitempty" jsonschema:"RFC3339 start time; defaults to now"`
	To    string `json:"to,omitempty" jsonschema:"RFC3339 end time; defaults to 24 hours after from"`
	Limit int    `json:"limit,omitempty" jsonschema:"maximum number of events; defaults to 100"`
}

type getEventInput struct {
	ID string `json:"id" jsonschema:"Calendar.app event ID"`
}

type freeBusyInput struct {
	From   string   `json:"from,omitempty" jsonschema:"RFC3339 start time; defaults to now"`
	To     string   `json:"to,omitempty" jsonschema:"RFC3339 end time; defaults to 24 hours after from"`
	Emails []string `json:"emails,omitempty" jsonschema:"optional email labels; availability is derived only from the local calendar"`
}

type calendarsOutput struct {
	Calendars []types.Calendar `json:"calendars"`
}

type eventsOutput struct {
	Events []types.Event `json:"events"`
}

type eventOutput struct {
	Event *types.Event `json:"event"`
}

type freeBusyOutput struct {
	Results []types.FreeBusyResult `json:"results"`
}

func (server *Server) listCalendars(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, calendarsOutput, error) {
	calendars, err := server.backend.ListCalendars(ctx)
	return nil, calendarsOutput{Calendars: calendars}, err
}

func (server *Server) listEvents(ctx context.Context, _ *mcp.CallToolRequest, input listEventsInput) (*mcp.CallToolResult, eventsOutput, error) {
	from, to, err := parseRange(input.From, input.To)
	if err != nil {
		return nil, eventsOutput{}, err
	}
	events, err := server.backend.ListEvents(ctx, from, to)
	if err != nil {
		return nil, eventsOutput{}, err
	}
	if input.Limit > 0 && len(events) > input.Limit {
		events = events[:input.Limit]
	}
	return nil, eventsOutput{Events: events}, nil
}

func (server *Server) getEvent(ctx context.Context, _ *mcp.CallToolRequest, input getEventInput) (*mcp.CallToolResult, eventOutput, error) {
	event, err := server.backend.GetEvent(ctx, strings.TrimSpace(input.ID))
	return nil, eventOutput{Event: event}, err
}

func (server *Server) getFreeBusy(ctx context.Context, _ *mcp.CallToolRequest, input freeBusyInput) (*mcp.CallToolResult, freeBusyOutput, error) {
	from, to, err := parseRange(input.From, input.To)
	if err != nil {
		return nil, freeBusyOutput{}, err
	}
	results, err := server.backend.GetFreeBusy(ctx, input.Emails, from, to)
	return nil, freeBusyOutput{Results: results}, err
}

func parseRange(fromValue, toValue string) (time.Time, time.Time, error) {
	from := time.Now()
	if strings.TrimSpace(fromValue) != "" {
		parsed, err := time.Parse(time.RFC3339, fromValue)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("parse from as RFC3339: %w", err)
		}
		from = parsed
	}
	to := from.Add(24 * time.Hour)
	if strings.TrimSpace(toValue) != "" {
		parsed, err := time.Parse(time.RFC3339, toValue)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("parse to as RFC3339: %w", err)
		}
		to = parsed
	}
	if !from.Before(to) {
		return time.Time{}, time.Time{}, fmt.Errorf("from must be before to")
	}
	return from, to, nil
}
