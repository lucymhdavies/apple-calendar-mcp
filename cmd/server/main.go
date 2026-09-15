package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/lucymhdavies/outlook-calendar/internal/backend/macos"
	"github.com/lucymhdavies/outlook-calendar/internal/mcpserver"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func main() {
	calendarName := os.Getenv("CALENDAR_NAME")
	log.SetFlags(log.LstdFlags)
	log.SetPrefix("[outlook-calendar] ")
	log.SetOutput(os.Stderr)
	log.Printf("starting server (CALENDAR_NAME=%q)", calendarName)
	server := mcpserver.New(macos.New(calendarName)).MCP()
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	log.Print("server stopped")
}
