package types

import "time"

type Calendar struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Color       string `json:"color,omitempty"`
	CanEdit     bool   `json:"can_edit"`
}

type Event struct {
	ID         string     `json:"id"`
	CalendarID string     `json:"calendar_id,omitempty"`
	Subject    string     `json:"subject"`
	Body       string     `json:"body,omitempty"`
	Start      time.Time  `json:"start"`
	End        time.Time  `json:"end"`
	Location   string     `json:"location,omitempty"`
	IsAllDay   bool       `json:"is_all_day"`
	Organizer  string     `json:"organizer,omitempty"`
	Attendees  []Attendee `json:"attendees,omitempty"`
	WebLink    string     `json:"web_link,omitempty"`
	Recurrence string     `json:"recurrence,omitempty"`
	Status     string     `json:"status,omitempty"`
}

type Attendee struct {
	Name   string `json:"name,omitempty"`
	Email  string `json:"email"`
	Type   string `json:"type,omitempty"`
	Status string `json:"status,omitempty"`
}

type FreeBusyResult struct {
	Email        string     `json:"email"`
	Availability string     `json:"availability,omitempty"`
	BusySlots    []TimeSlot `json:"busy_slots,omitempty"`
	Source       string     `json:"source,omitempty"`
	Note         string     `json:"note,omitempty"`
}

type TimeSlot struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
}
