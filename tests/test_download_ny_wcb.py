import sys
from pathlib import Path

import pyarrow as pa

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from download_ny_wcb import normalize_name, page_to_table  # noqa: E402


def test_normalize_name():
    assert normalize_name("Attorney/Representative") == "ATTORNEY_REPRESENTATIVE"
    assert normalize_name("COVID-19 Indicator") == "COVID_19_INDICATOR"
    assert normalize_name("WCIO Part Of Body Code") == "WCIO_PART_OF_BODY_CODE"
    assert normalize_name("C-2 Date") == "C_2_DATE"


def test_page_to_table_fills_missing_fields_with_null_strings():
    columns = {"claim_identifier": "CLAIM_IDENTIFIER", "attorney_representative": "ATTORNEY_REPRESENTATIVE",
               "age_at_injury": "AGE_AT_INJURY"}
    # The API omits null fields, and the second record has no age.
    records = [
        {"claim_identifier": "1", "attorney_representative": "Y", "age_at_injury": "41"},
        {"claim_identifier": "2", "attorney_representative": "N"},
    ]
    table = page_to_table(records, columns)
    assert table.column_names == ["CLAIM_IDENTIFIER", "ATTORNEY_REPRESENTATIVE", "AGE_AT_INJURY"]
    assert all(field.type == pa.string() for field in table.schema)
    assert table.column("AGE_AT_INJURY").to_pylist() == ["41", None]


def test_page_to_table_schema_is_stable_when_a_column_is_entirely_null():
    columns = {"claim_identifier": "CLAIM_IDENTIFIER", "gender": "GENDER"}
    table = page_to_table([{"claim_identifier": "1"}], columns)
    assert table.schema.field("GENDER").type == pa.string()
