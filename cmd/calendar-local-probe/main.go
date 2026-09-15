package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type calendarEvent struct {
	ID          string     `json:"id"`
	Calendar    string     `json:"calendar"`
	Title       string     `json:"title"`
	Description string     `json:"description,omitempty"`
	Start       time.Time  `json:"start"`
	End         time.Time  `json:"end"`
	IsAllDay    bool       `json:"is_all_day"`
	Location    string     `json:"location,omitempty"`
	URL         string     `json:"url,omitempty"`
	Recurrence  string     `json:"recurrence,omitempty"`
	Status      string     `json:"status,omitempty"`
	Attendees   []attendee `json:"attendees,omitempty"`
}

type attendee struct {
	Email  string `json:"email"`
	Name   string `json:"name,omitempty"`
	Status string `json:"status,omitempty"`
}

func main() {
	calendarName := flag.String("calendar", "Calendar", "Calendar.app calendar name")
	days := flag.Int("days", 14, "number of days from now to query")
	limit := flag.Int("limit", 100, "maximum number of events to return")
	flag.Parse()

	if *days < 1 || *limit < 1 {
		fatal(fmt.Errorf("days and limit must be positive"))
	}

	output, err := runAppleScript(*calendarName, *days, *limit)
	if err != nil {
		fatal(err)
	}

	events, err := parseEvents(output, *calendarName)
	if err != nil {
		fatal(err)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(events); err != nil {
		fatal(fmt.Errorf("encode events: %w", err))
	}
}

func runAppleScript(calendarName string, days, limit int) (string, error) {
	calendarLiteral := strings.ReplaceAll(strings.ReplaceAll(calendarName, `\`, `\\`), `"`, `\"`)
	script := fmt.Sprintf(`
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

set windowStart to current date
set windowEnd to windowStart + (%d * days)
set epochDate to date "1/1/1970"
with timeout of 300 seconds
	tell application "Calendar"
	set fieldSeparator to character id 31
		set attendeeSeparator to character id 30
		set attendeeFieldSeparator to character id 29
	set matchingEvents to every event of calendar "%s" whose start date < windowEnd and end date > windowStart
	set output to ""
	set maximumEvents to %d
	if (count of matchingEvents) < maximumEvents then set maximumEvents to count of matchingEvents
	repeat with index from 1 to maximumEvents
		set currentEvent to item index of matchingEvents
		set eventID to id of currentEvent
		set eventSummary to my sanitize(summary of currentEvent)
		set eventDescription to my optionalText(description of currentEvent)
		set eventStart to start date of currentEvent
		set eventEnd to end date of currentEvent
		set eventAllDay to allday event of currentEvent
		set eventLocation to location of currentEvent
		if eventLocation is missing value then set eventLocation to ""
		set eventLocation to my sanitize(eventLocation)
		set eventURL to my optionalText(url of currentEvent)
		set eventRecurrence to my optionalText(recurrence of currentEvent)
		set eventStatus to my optionalText(status of currentEvent)
		set attendeeOutput to ""
		set eventAttendees to every attendee of currentEvent
		repeat with attendeeIndex from 1 to (count of eventAttendees)
			set currentAttendee to item attendeeIndex of eventAttendees
			set attendeeEmail to my optionalText(email of currentAttendee)
			set attendeeName to my optionalText(display name of currentAttendee)
			set attendeeStatus to my optionalText(participation status of currentAttendee)
			if attendeeIndex > 1 then set attendeeOutput to attendeeOutput & attendeeSeparator
			set attendeeOutput to attendeeOutput & attendeeEmail & attendeeFieldSeparator & attendeeName & attendeeFieldSeparator & attendeeStatus
		end repeat
		set startEpoch to (eventStart - epochDate) as integer
		set endEpoch to (eventEnd - epochDate) as integer
		set output to output & eventID & fieldSeparator & eventSummary & fieldSeparator & eventDescription & fieldSeparator & startEpoch & fieldSeparator & endEpoch & fieldSeparator & eventAllDay & fieldSeparator & eventLocation & fieldSeparator & eventURL & fieldSeparator & eventRecurrence & fieldSeparator & eventStatus & fieldSeparator & attendeeOutput & linefeed
	end repeat
	end tell
end timeout
return output
`, days, calendarLiteral, limit)

	command := exec.Command("osascript", "-e", script)
	result, err := command.Output()
	if err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("Calendar.app query failed: %s", strings.TrimSpace(string(exitError.Stderr)))
		}
		return "", fmt.Errorf("run osascript: %w", err)
	}
	return string(result), nil
}

func parseEvents(output, calendarName string) ([]calendarEvent, error) {
	events := make([]calendarEvent, 0)
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		fields := strings.Split(scanner.Text(), string(rune(31)))
		if len(fields) != 11 {
			return nil, fmt.Errorf("unexpected Calendar.app row with %d fields", len(fields))
		}
		start, err := parseAppleScriptTime(fields[3])
		if err != nil {
			return nil, fmt.Errorf("parse event start: %w", err)
		}
		end, err := parseAppleScriptTime(fields[4])
		if err != nil {
			return nil, fmt.Errorf("parse event end: %w", err)
		}
		isAllDay, err := strconv.ParseBool(fields[5])
		if err != nil {
			return nil, fmt.Errorf("parse all-day value: %w", err)
		}
		events = append(events, calendarEvent{
			ID:          fields[0],
			Calendar:    calendarName,
			Title:       fields[1],
			Description: fields[2],
			Start:       start,
			End:         end,
			IsAllDay:    isAllDay,
			Location:    fields[6],
			URL:         fields[7],
			Recurrence:  fields[8],
			Status:      fields[9],
			Attendees:   parseAttendees(fields[10]),
		})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read Calendar.app output: %w", err)
	}
	return events, nil
}

func parseAttendees(value string) []attendee {
	if value == "" {
		return nil
	}
	attendees := make([]attendee, 0)
	for _, encoded := range strings.Split(value, string(rune(30))) {
		fields := strings.Split(encoded, string(rune(29)))
		if len(fields) != 3 {
			continue
		}
		attendees = append(attendees, attendee{Email: fields[0], Name: fields[1], Status: fields[2]})
	}
	return attendees
}

func parseAppleScriptTime(value string) (time.Time, error) {
	secondsFloat, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return time.Time{}, err
	}
	seconds := int64(secondsFloat)
	localCandidate := time.Unix(seconds, 0)
	_, offset := localCandidate.Zone()
	return time.Unix(seconds-int64(offset), 0), nil
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
