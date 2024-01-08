import csv
import os

from dotenv import load_dotenv

from g_sheets_writer import write_sheet
from g_copy_template_sheet import copy_file


def extract_data_from_csv(filedir):
	try:
		with open(filedir, 'r') as csvfile:
			reader = csv.reader(csvfile, delimiter=';')
			reader = [row for row in reader]
			currency = reader[1][1]
			reader.pop(0)
			data = [
				[
					int(row[0]),
					float(row[4]),
					int(row[10]),
					float(row[5]),
					float(row[6]),
					float(row[7]),
					float(row[8]),
					float(row[9]),
					float(row[67][8:]),
					float(row[68][8:]),
					float(row[69][8:]),
					float(row[70][8:]),
					float(row[71][8:]),
					float(row[72][8:]),
					float(row[73][8:])
				]
				for row in reader
			]
		return {
			"data": data,
			"currency": currency,
		}
	except OSError as exc:
		if exc.errno == 63:
			pass
		else:
			raise


def main():
	load_dotenv()
	dirname: str = str(input("Enter dirname:\t"))
	folder_path = os.path.join(os.path.dirname(__file__), os.pardir, "data", dirname)
	data_folder = os.listdir(folder_path)

	if not data_folder:
		print("No data")
	spreadsheet_id = copy_file(dirname)
	print(data_folder)
	for filename in data_folder:
		if not filename.endswith(".csv"):
			return
		data = extract_data_from_csv(f"{folder_path}/{filename}")
		result = write_sheet(data["data"], data["currency"], spreadsheet_id)
		print(result)


if __name__ == '__main__':
	main()
