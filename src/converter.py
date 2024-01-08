import csv
import os

from dotenv import load_dotenv

from g_sheets_writer import write_sheet
from g_copy_template_sheet import copy_file


def find_inputs(data):
	first_input = 0
	for i, v in enumerate(data):
		if v[:8] == "INPUT_1=":
			first_input = i
	return [[
		float(row[first_input + n][8:]) if n < 9
		else float(row[first_input + n][9:])
		for n in range(25)
	] for row in data]


def extract_data_from_csv(filedir):
	try:
		with open(filedir, 'r') as csvfile:
			reader = csv.reader(csvfile, delimiter=';')
			reader = [row for row in reader]
			currency = reader[1][1]
			reader.pop(0)
			inputs = find_inputs(reader)
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
					*inputs[i]
				]
				for i, row in enumerate(reader)
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
