package main

import (
	"context"
	"fmt"
	"os"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	msgraphsdk "github.com/microsoftgraph/msgraph-sdk-go"
)

const (
	clientID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
	tenantID = "common"
)

var scopes = []string{"User.Read", "Calendars.Read", "offline_access"}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run() error {
	configuredClientID := os.Getenv("AZURE_CLIENT_ID")
	if configuredClientID == "" {
		configuredClientID = clientID
	}
	configuredTenantID := os.Getenv("AZURE_TENANT_ID")
	if configuredTenantID == "" {
		configuredTenantID = tenantID
	}

	cred, err := azidentity.NewDeviceCodeCredential(&azidentity.DeviceCodeCredentialOptions{
		ClientID: configuredClientID,
		TenantID: configuredTenantID,
		UserPrompt: func(ctx context.Context, msg azidentity.DeviceCodeMessage) error {
			fmt.Println(msg.Message)
			return nil
		},
	})
	if err != nil {
		return fmt.Errorf("create credential: %w", err)
	}

	client, err := msgraphsdk.NewGraphServiceClientWithCredentials(cred, scopes)
	if err != nil {
		return fmt.Errorf("create graph client: %w", err)
	}

	me, err := client.Me().Get(context.Background(), nil)
	if err != nil {
		return fmt.Errorf("GET /me: %w", err)
	}

	displayName := ""
	if me.GetDisplayName() != nil {
		displayName = *me.GetDisplayName()
	}
	mail := ""
	if me.GetMail() != nil {
		mail = *me.GetMail()
	}

	fmt.Printf("Display Name: %s\n", displayName)
	fmt.Printf("Mail:         %s\n", mail)
	return nil
}
