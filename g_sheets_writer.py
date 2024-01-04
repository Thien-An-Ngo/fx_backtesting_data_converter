import os.path

import google.auth
from googleapiclient.discovery import build
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.errors import HttpError


SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]
SPREADSHEET_ID = "1Jce-DBqaNEopsqmNzqmXuSjUKmu_makXmjwVenqaZqM"


def write_sheet(data, sheet_id):
	creds = None
	if os.path.exists("token.json"):
		creds = Credentials.from_authorized_user_file("token.json", SCOPES)
	if not creds or not creds.valid:
		if creds and creds.expired and creds.refresh_token:
			creds.refresh(Request())
		else:
			flow = InstalledAppFlow.from_client_secrets_file(
				"credentials.json", SCOPES
			)
			creds = flow.run_local_server(port=0)
		# Save the credentials for the next run
		with open("token.json", "w") as token:
			token.write(creds.to_json())
	try:
		return write_data(data, f'{sheet_id}!A5', creds)
	except HttpError as err:
		print(err)


def write_data(_values, range_name, creds, spreadsheet_id=SPREADSHEET_ID, value_input_option="USER_ENTERED"):
	print(f"range: {range_name}")
	try:
		service = build("sheets", "v4", credentials=creds)
		body = {"values": _values}
		result = (
			service.spreadsheets()
			.values()
			.update(
				spreadsheetId=spreadsheet_id,
				range=range_name,
				valueInputOption=value_input_option,
				body=body,
			)
			.execute()
		)
		print(f"{(result.get('totalUpdatedCells'))} cells updated.")
		return result
	except HttpError as error:
		print(f"An error occurred: {error}")
		return error


if __name__ == "__main__":
	write_sheet()
