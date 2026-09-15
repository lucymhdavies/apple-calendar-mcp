package mcpserver

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/backend"
	"github.com/lucymhdavies/outlook-calendar/internal/types"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var logger = log.New(os.Stderr, "[outlook-calendar] ", log.LstdFlags)

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
	logger.Print("list_calendars: start")
	start := time.Now()
	calendars, err := server.backend.ListCalendars(ctx)
	if err != nil {
		logger.Printf("list_calendars: error after %s: %v", time.Since(start).Round(time.Millisecond), err)
		return nil, calendarsOutput{}, err
	}
	logger.Printf("list_calendars: done in %s, returned %d calendars", time.Since(start).Round(time.Millisecond), len(calendars))
	return nil, calendarsOutput{Calendars: calendars}, nil
}

func (server *Server) listEvents(ctx context.Context, _ *mcp.CallToolRequest, input listEventsInput) (*mcp.CallToolResult, eventsOutput, error) {
	from, to, err := parseRange(input.From, input.To)
	if err != nil {
		logger.Printf("list_events: bad range from=%q to=%q: %v", input.From, input.To, err)
		return nil, eventsOutput{}, err
	}
	logger.Printf("list_events: start from=%s to=%s limit=%d", from.Format(time.RFC3339), to.Format(time.RFC3339), input.Limit)
	start := time.Now()
	events, err := server.backend.ListEvents(ctx, from, to)
	if err != nil {
		logger.Printf("list_events: error after %s: %v", time.Since(start).Round(time.Millisecond), err)
		return nil, eventsOutput{}, err
	}
	if input.Limit > 0 && len(events) > input.Limit {
		events = events[:input.Limit]
	}
	logger.Printf("list_events: done in %s, returned %d events", time.Since(start).Round(time.Millisecond), len(events))
	return nil, eventsOutput{Events: events}, nil
}

func (server *Server) getEvent(ctx context.Context, _ *mcp.CallToolRequest, input getEventInput) (*mcp.CallToolResult, eventOutput, error) {
	id := strings.TrimSpace(input.ID)
	logger.Printf("get_event: start id=%q", id)
	start := time.Now()
	event, err := server.backend.GetEvent(ctx, id)
	if err != nil {
		logger.Printf("get_event: error after %s: %v", time.Since(start).Round(time.Millisecond), err)
		return nil, eventOutput{}, err
	}
	logger.Printf("get_event: done in %s", time.Since(start).Round(time.Millisecond))
	return nil, eventOutput{Event: event}, nil
}

func (server *Server) getFreeBusy(ctx context.Context, _ *mcp.CallToolRequest, input freeBusyInput) (*mcp.CallToolResult, freeBusyOutput, error) {
	from, to, err := parseRange(input.From, input.To)
	if err != nil {
		logger.Printf("get_freebusy: bad range from=%q to=%q: %v", input.From, input.To, err)
		return nil, freeBusyOutput{}, err
	}
	logger.Printf("get_freebusy: start from=%s to=%s emails=%v", from.Format(time.RFC3339), to.Format(time.RFC3339), input.Emails)
	start := time.Now()
	results, err := server.backend.GetFreeBusy(ctx, input.Emails, from, to)
	if err != nil {
		logger.Printf("get_freebusy: error after %s: %v", time.Since(start).Round(time.Millisecond), err)
		return nil, freeBusyOutput{}, err
	}
	logger.Printf("get_freebusy: done in %s, returned %d results", time.Since(start).Round(time.Millisecond), len(results))
	return nil, freeBusyOutput{Results: results}, nil
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
