import os

from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from g_credentials_login import g_credentials


def write_sheet(data, sheet_id, spreadsheet_id="1Jce-DBqaNEopsqmNzqmXuSjUKmu_makXmjwVenqaZqM"):
	creds = g_credentials()
	try:
		return write_data(data, f'{sheet_id}!A5', creds, spreadsheet_id)
	except HttpError as err:
		print(err)


def write_data(_values, range_name, creds, spreadsheet_id, value_input_option="USER_ENTERED"):
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
		print(service.spreadsheets())
		print(f"{result}")
		return result
	except HttpError as error:
		print(f"An error occurred: {error}")
		return error

