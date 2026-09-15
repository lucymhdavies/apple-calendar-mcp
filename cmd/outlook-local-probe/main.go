package main

import (
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

type calendarEvent struct {
	ID            int64  `json:"id"`
	CalendarUID   string `json:"calendar_uid"`
	ExchangeID    string `json:"exchange_id,omitempty"`
	FolderID      int64  `json:"folder_id"`
	AccountUID    int64  `json:"account_uid"`
	StartUTC      string `json:"start_utc,omitempty"`
	EndUTC        string `json:"end_utc,omitempty"`
	IsRecurring   bool   `json:"is_recurring"`
	AttendeeCount int64  `json:"attendee_count"`
}

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		fatal(err)
	}

	defaultDB := filepath.Join(home, "Library", "Group Containers", "UBF8T346G9.Office", "Outlook", "Outlook 15 Profiles", "Main Profile", "Data", "Outlook.sqlite")
	databasePath := flag.String("db", defaultDB, "path to Outlook.sqlite")
	limit := flag.Int("limit", 100, "maximum number of events to return")
	flag.Parse()

	db, err := sql.Open("sqlite", "file:"+*databasePath+"?mode=ro")
	if err != nil {
		fatal(fmt.Errorf("open Outlook database: %w", err))
	}
	defer db.Close()

	rows, err := db.Query(`
		SELECT
			Record_RecordID,
			Calendar_UID,
			Record_ExchangeOrEasId,
			Record_FolderID,
			Record_AccountUID,
			Calendar_StartDateUTC,
			Calendar_EndDateUTC,
			Calendar_IsRecurring,
			Calendar_AttendeeCount
		FROM CalendarEvents
		ORDER BY Calendar_StartDateUTC ASC
		LIMIT ?`, *limit)
	if err != nil {
		fatal(fmt.Errorf("query CalendarEvents: %w", err))
	}
	defer rows.Close()

	events := make([]calendarEvent, 0)
	for rows.Next() {
		var event calendarEvent
		if err := rows.Scan(
			&event.ID,
			&event.CalendarUID,
			&event.ExchangeID,
			&event.FolderID,
			&event.AccountUID,
			&event.StartUTC,
			&event.EndUTC,
			&event.IsRecurring,
			&event.AttendeeCount,
		); err != nil {
			fatal(fmt.Errorf("scan CalendarEvents: %w", err))
		}
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		fatal(fmt.Errorf("read CalendarEvents: %w", err))
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(events); err != nil {
		fatal(fmt.Errorf("encode events: %w", err))
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
