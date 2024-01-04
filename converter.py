import csv

from g_sheets_writer import write_sheet


def extract_data_from_csv():
	with open('data/SSL_C_EURUSD.csv', 'r') as csvfile:
		reader = csv.reader(csvfile, delimiter=';')
		reader = [row for row in reader]
		currency = reader[1][1]
		reader.pop(0)
		data = [
			[int(row[0]), float(row[4]), int(row[10]), float(row[5]), float(row[6]), float(row[7]), float(row[8]), float(row[9])]
			for row in reader
		]
	return {
		"data": data,
		"currency": currency,
	}


def convert_data():
	res = extract_data_from_csv()
	print(res)
	result = write_sheet(res["data"], res["currency"])
	print(result)


if __name__ == '__main__':
	convert_data()
