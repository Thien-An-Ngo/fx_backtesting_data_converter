import os
from dotenv import load_dotenv


def main():
	load_dotenv()
	print(os.listdir(os.path.join(os.path.dirname(__file__), os.pardir, "data")))


if __name__ == '__main__':
	main()
