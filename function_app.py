import datetime
import json
import logging
import os
import struct

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings
import pyodbc
import requests

app = func.FunctionApp()

# Module-level credential instance (reuses token cache across invocations)
AZURE_CREDENTIAL = DefaultAzureCredential()


@app.timer_trigger(
    schedule="0 0 6 * * *",
    arg_name="my_timer",
    run_on_startup=False,
    use_monitor=True,
)
def fetch_market_prices(my_timer: func.TimerRequest) -> None:
    utc_timestamp = datetime.datetime.now(datetime.timezone.utc)
    api_url = os.environ.get(
        "MARKET_DATA_API_URL",
        "https://open.er-api.com/v6/latest/USD",
    )
    container_name = os.environ.get("BLOB_CONTAINER_NAME", "raw-market-data")

    logging.info("Market price ingestion started at %s", utc_timestamp.isoformat())

    response = requests.get(api_url, timeout=15)
    response.raise_for_status()
    raw_payload = response.json()

    document = {
        "ingestion_metadata": {
            "ingested_at_utc": utc_timestamp.isoformat(),
            "source_endpoint": api_url,
            "status_code": response.status_code,
        },
        "payload": raw_payload,
    }

    blob_path = (
        f"year={utc_timestamp:%Y}/"
        f"month={utc_timestamp:%m}/"
        f"market_prices_{utc_timestamp:%Y%m%d_%H%M%S}.json"
    )

    blob_service_client = create_blob_service_client()
    blob_client = blob_service_client.get_blob_client(
        container=container_name,
        blob=blob_path,
    )
    blob_client.upload_blob(
        json.dumps(document, separators=(",", ":")),
        overwrite=True,
        content_settings=ContentSettings(content_type="application/json"),
    )
    logging.info("Wrote %s/%s", container_name, blob_path)


def create_blob_service_client() -> BlobServiceClient:
    connection_string = os.environ.get("BLOB_STORAGE_CONNECTION_STRING")
    if connection_string:
        return BlobServiceClient.from_connection_string(connection_string)

    account_url = os.environ["BLOB_STORAGE_ACCOUNT_URL"]
    return BlobServiceClient(
        account_url=account_url,
        credential=AZURE_CREDENTIAL,
    )


@app.blob_trigger(
    arg_name="my_blob",
    path="%BLOB_CONTAINER_NAME%/year={year}/month={month}/{name}.json",
    connection="BLOB_STORAGE_CONNECTION",
)
def stage_blob_to_sql(my_blob: func.InputStream) -> None:
    """Validate a landed payload and stage it through the SQL procedure."""
    blob_name = my_blob.name.rsplit("/", 1)[-1]
    payload = my_blob.read()

    try:
        document = json.loads(payload.decode("utf-8"))
        if "ingestion_metadata" not in document or "payload" not in document:
            raise ValueError("Payload must contain ingestion_metadata and payload")

        server = os.environ["SQL_SERVER_FQDN"]
        database = os.environ["SQL_DATABASE_NAME"]
        connection_string = (
            "Driver={ODBC Driver 18 for SQL Server};"
            f"Server=tcp:{server},1433;Database={database};"
            "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        )
        
        token = AZURE_CREDENTIAL.get_token(
            "https://database.windows.net/.default"
        ).token.encode("utf-16-le")
        token_struct = struct.pack(f"<I{len(token)}s", len(token), token)

        json_str = json.dumps(document, separators=(",", ":"))

        with pyodbc.connect(
            connection_string,
            attrs_before={1256: token_struct},
        ) as connection:
            cursor = connection.cursor()
            # Explicitly set parameter as NVARCHAR(MAX) to prevent truncation on large JSON
            cursor.setinputsizes([(pyodbc.SQL_WVARCHAR, 0, 0)])
            cursor.execute(
                "EXEC dbo.sp_stage_market_prices @json_payload = ?",
                json_str,
            )
            connection.commit()

        logging.info("Staged %s into Azure SQL", my_blob.name)
    except Exception as error:
        logging.exception("Unable to stage %s", my_blob.name)
        route_to_deadletter(blob_name, payload, str(error), "PROCESSING_ERROR")
        raise


def route_to_deadletter(blob_name: str, payload: bytes, error: str, reason: str) -> None:
    container_name = os.environ.get(
        "DEADLETTER_CONTAINER_NAME", "raw-market-data-deadletter"
    )
    client = create_blob_service_client().get_blob_client(
        container=container_name,
        blob=f"failed/{reason.lower()}/{blob_name}",
    )
    client.upload_blob(
        payload,
        overwrite=True,
        metadata={"error_reason": reason, "error_details": error[:1000]},
        content_settings=ContentSettings(content_type="application/json"),
    )
    
git add function_app.py requirements.txt
git commit -m "feat: implement timer ingestion and sql staging blob trigger"
git push origin main