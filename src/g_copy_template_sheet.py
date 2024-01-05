import os

from dotenv import load_dotenv
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from g_credentials_login import g_credentials


def copy_file(title, file_id=None, dir_id=None, copied_from=None):
	creds = g_credentials()
	file = file_id or os.getenv("SPREADSHEET_TEMPLATE_ID")
	folder = dir_id or os.getenv("RES_DIR_ID")
	copies_folder = copied_from or os.getenv("COPIES_FOLDER")
	title is None and print("Please insert title")
	# pylint: disable=maybe-no-member
	try:
		service = build("drive", "v3", credentials=creds)
		res_copy = service.files().copy(
			fileId=file,
			body={
				"parents": [{
					"id": folder
				}],
				"name": title
			}).execute()
		newfile_id = res_copy["id"]
		res_move = service.files().update(
			fileId=newfile_id,
			addParents=folder,
			removeParents=copies_folder,
			fields='id, parents'
		).execute()
		return newfile_id
	except HttpError as error:
		print(f"An error occurred: {error}")
		return error


if __name__ == "__main__":
	load_dotenv()
	copy_file("HURZ")
