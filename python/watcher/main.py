from watcher.utils import get_greeting
from google import genai
import os


def main() -> None:
    print(os.environ["GOOGLE_API_KEY"])
    print(get_greeting())


if __name__ == "__main__":
    main()
