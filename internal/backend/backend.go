package backend

import (
	"context"
	"time"

	"github.com/lucymhdavies/outlook-calendar/internal/types"
)

type Backend interface {
	ListCalendars(context.Context) ([]types.Calendar, error)
	ListEvents(context.Context, time.Time, time.Time) ([]types.Event, error)
	GetEvent(context.Context, string) (*types.Event, error)
	GetFreeBusy(context.Context, []string, time.Time, time.Time) ([]types.FreeBusyResult, error)
}