package macos

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/types"
)

const (
	fieldSep  = byte(31)
	recordSep = byte(30)
	valueSep  = byte(29)
)

type Backend struct{ calendarName string }

var _ interface {
	ListCalendars(context.Context) ([]types.Calendar, error)
	ListEvents(context.Context, time.Time, time.Time) ([]types.Event, error)
	GetEvent(context.Context, string) (*types.Event, error)
	GetFreeBusy(context.Context, []string, time.Time, time.Time) ([]types.FreeBusyResult, error)
} = (*Backend)(nil)

func New(calendarName string) *Backend {
	if calendarName == "" {
		calendarName = "Calendar"
	}
	return &Backend{calendarName: calendarName}
}

func (b *Backend) ListCalendars(ctx context.Context) ([]types.Calendar, error) {
	out, err := b.run(ctx, calendarScript)
	if err != nil {
		return nil, err
	}
	var result []types.Calendar
	s := bufio.NewScanner(strings.NewReader(out))
	for s.Scan() {
		parts := strings.Split(s.Text(), string(fieldSep))
		if len(parts) == 2 && parts[0] != "" {
			result = append(result, types.Calendar{ID: parts[0], Name: parts[1], CanEdit: true})
		}
	}
	return result, s.Err()
}

func (b *Backend) ListEvents(ctx context.Context, from, to time.Time) ([]types.Event, error) {
	if !from.Before(to) {
		return []types.Event{}, nil
	}
	now := time.Now()
	script := fmt.Sprintf(eventScript, quote(b.calendarName), from.Sub(now).Seconds(), to.Sub(now).Seconds())
	out, err := b.run(ctx, script)
	if err != nil {
		return nil, err
	}
	events, err := parseEvents(out, b.calendarName)
	if err != nil {
		return nil, err
	}
	filtered := events[:0]
	for _, event := range events {
		if event.Start.Before(to) && event.End.After(from) {
			filtered = append(filtered, event)
		}
	}
	return filtered, nil
}

func (b *Backend) GetEvent(ctx context.Context, id string) (*types.Event, error) {
	if id == "" {
		return nil, fmt.Errorf("event ID is required")
	}
	out, err := b.run(ctx, fmt.Sprintf(eventByIDScript, quote(b.calendarName), 0.0, 0.0, quote(id)))
	if err != nil {
		return nil, err
	}
	events, err := parseEvents(out, b.calendarName)
	if err != nil {
		return nil, err
	}
	if len(events) == 0 {
		return nil, fmt.Errorf("event %q not found", id)
	}
	return &events[0], nil
}

func (b *Backend) GetFreeBusy(ctx context.Context, emails []string, from, to time.Time) ([]types.FreeBusyResult, error) {
	events, err := b.ListEvents(ctx, from, to)
	if err != nil {
		return nil, err
	}
	slots := make([]types.TimeSlot, 0, len(events))
	for _, event := range events {
		slots = append(slots, types.TimeSlot{Start: event.Start, End: event.End})
	}
	if len(emails) == 0 {
		emails = []string{""}
	}
	result := make([]types.FreeBusyResult, 0, len(emails))
	for _, email := range emails {
		result = append(result, types.FreeBusyResult{Email: email, Availability: "local", BusySlots: slots, Source: "macos-calendar", Note: "Derived from locally synced macOS Calendar; cross-user free/busy is unavailable."})
	}
	return result, nil
}

func (b *Backend) run(ctx context.Context, script string) (string, error) {
	command := exec.CommandContext(ctx, "osascript", "-e", script)
	out, err := command.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("Calendar.app query failed: %s", strings.TrimSpace(string(exitErr.Stderr)))
		}
		return "", fmt.Errorf("run osascript: %w", err)
	}
	return string(out), nil
}

func quote(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, `\`, `\\`), `"`, `\"`)
}

func parseEvents(output, calendarName string) ([]types.Event, error) {
	result := make([]types.Event, 0)
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		parts := strings.Split(scanner.Text(), string(fieldSep))
		if len(parts) != 11 {
			return nil, fmt.Errorf("unexpected Calendar.app event row with %d fields", len(parts))
		}
		start, err := parseTime(parts[3])
		if err != nil {
			return nil, fmt.Errorf("parse event start: %w", err)
		}
		end, err := parseTime(parts[4])
		if err != nil {
			return nil, fmt.Errorf("parse event end: %w", err)
		}
		allDay, err := strconv.ParseBool(parts[5])
		if err != nil {
			return nil, fmt.Errorf("parse all-day value: %w", err)
		}
		result = append(result, types.Event{ID: parts[0], CalendarID: calendarName, Subject: parts[1], Body: parts[2], Start: start, End: end, IsAllDay: allDay, Location: parts[6], WebLink: parts[7], Recurrence: parts[8], Status: parts[9], Attendees: parseAttendees(parts[10])})
	}
	return result, scanner.Err()
}

func parseAttendees(value string) []types.Attendee {
	if value == "" {
		return nil
	}
	result := make([]types.Attendee, 0)
	for _, record := range strings.Split(value, string(recordSep)) {
		parts := strings.Split(record, string(valueSep))
		if len(parts) == 3 {
			result = append(result, types.Attendee{Email: parts[0], Name: parts[1], Status: parts[2]})
		}
	}
	return result
}

func parseTime(value string) (time.Time, error) {
	secondsFloat, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return time.Time{}, err
	}
	seconds := int64(secondsFloat)
	candidate := time.Unix(seconds, 0)
	_, offset := candidate.Zone()
	return time.Unix(seconds-int64(offset), 0), nil
}

const calendarScript = `
on sanitize(value)
 set value to value as text
 set AppleScript's text item delimiters to {return, linefeed, tab, character id 29, character id 30, character id 31}
 set parts to text items of value
 set AppleScript's text item delimiters to " "
 set value to parts as text
 set AppleScript's text item delimiters to ""
 return value
end sanitize
set separator to character id 31
set output to ""
tell application "Calendar"
 repeat with currentCalendar in every calendar
  set output to output & (id of currentCalendar) & separator & (my sanitize(name of currentCalendar)) & linefeed
 end repeat
end tell
return output
`

const eventScript = `
on sanitize(value)
 set value to value as text
 set AppleScript's text item delimiters to {return, linefeed, tab, character id 29, character id 30, character id 31}
 set parts to text items of value
 set AppleScript's text item delimiters to " "
 set value to parts as text
 set AppleScript's text item delimiters to ""
 return value
end sanitize
on optionalText(value)
 if value is missing value then return ""
 return my sanitize(value)
end optionalText
set windowStart to (current date) + %[2]f
set windowEnd to (current date) + %[3]f
set epochDate to date "1/1/1970"
with timeout of 300 seconds
 tell application "Calendar"
  set fieldSeparator to character id 31
  set attendeeSeparator to character id 30
  set attendeeFieldSeparator to character id 29
  set matchingEvents to every event of calendar "%[1]s" whose start date < windowEnd and end date > windowStart
  set output to ""
  repeat with currentEvent in matchingEvents
   set attendeeOutput to ""
   set eventAttendees to every attendee of currentEvent
   repeat with attendeeIndex from 1 to (count of eventAttendees)
    set currentAttendee to item attendeeIndex of eventAttendees
    if attendeeIndex > 1 then set attendeeOutput to attendeeOutput & attendeeSeparator
    set attendeeOutput to attendeeOutput & my optionalText(email of currentAttendee) & attendeeFieldSeparator & my optionalText(display name of currentAttendee) & attendeeFieldSeparator & my optionalText(participation status of currentAttendee)
   end repeat
   set startEpoch to (start date of currentEvent - epochDate) as integer
   set endEpoch to (end date of currentEvent - epochDate) as integer
   set output to output & (id of currentEvent) & fieldSeparator & my sanitize(summary of currentEvent) & fieldSeparator & my optionalText(description of currentEvent) & fieldSeparator & startEpoch & fieldSeparator & endEpoch & fieldSeparator & (allday event of currentEvent) & fieldSeparator & my optionalText(location of currentEvent) & fieldSeparator & my optionalText(url of currentEvent) & fieldSeparator & my optionalText(recurrence of currentEvent) & fieldSeparator & my optionalText(status of currentEvent) & fieldSeparator & attendeeOutput & linefeed
  end repeat
 end tell
end timeout
return output
`

var eventByIDScript = strings.ReplaceAll(eventScript, `set matchingEvents to every event of calendar "%[1]s" whose start date < windowEnd and end date > windowStart`, `set matchingEvents to every event of calendar "%[1]s" whose id is "%[4]s"`)
