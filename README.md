# postgis_aws_gis_poc
A template project for setting up an AWS hosted map application using open source technologies.

## API

### Prerequisites

- Python 3.12 (official [python.org](https://www.python.org/downloads/) build recommended). On Windows, verify the launcher can find it:

  ```powershell
  py -0p
  ```

  > Avoid MSYS2/MinGW Python — its interpreter is incompatible with PyPI's prebuilt wheels (e.g. `psycopg2-binary`) and will try to compile from source.

### Setup

All commands are run from the `api/` directory.

1. Create and activate a virtual environment:

   ```powershell
   cd api
   py -3.12 -m venv .venv
   .\.venv\Scripts\Activate.ps1
   ```

   On macOS/Linux:

   ```bash
   cd api
   python3.12 -m venv .venv
   source .venv/bin/activate
   ```

2. Install the dependencies:

   ```powershell
   python -m pip install --upgrade pip
   pip install -r requirements.txt
   ```

### Run the API

With the virtual environment activated, start the development server:

```powershell
uvicorn main:app --reload --host 0.0.0.0 --port 8001
```

The API will be available at http://127.0.0.1:8000 and the interactive docs at http://127.0.0.1:8000/docs.
