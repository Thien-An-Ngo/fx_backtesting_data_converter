import os.path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow


SCOPES = ["https://www.googleapis.com/auth/drive"]


def g_credentials():
	creds = None
	path = os.path.join(os.path.dirname(__file__), os.pardir)
	if os.path.exists(f"{path}/token.json"):
		creds = Credentials.from_authorized_user_file(f"{path}/token.json", SCOPES)
	if not creds or not creds.valid:
		if creds and creds.expired and creds.refresh_token:
			creds.refresh(Request())
		else:
			flow = InstalledAppFlow.from_client_secrets_file(
				f"{path}/credentials.json", SCOPES
			)
			creds = flow.run_local_server(port=0)
		# Save the credentials for the next run
		with open(f"{path}/token.json", "w") as token:
			token.write(creds.to_json())
	return creds


if __name__ == "__main__":
	g_credentials()
