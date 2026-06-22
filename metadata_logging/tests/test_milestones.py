import os
import sys
import json
import unittest

# Add src/ to python path
src_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
if src_dir not in sys.path:
    sys.path.insert(0, src_dir)

from transform import extract_milestones, format_as_log_entry

class TestCCaASMilestoneExtraction(unittest.TestCase):
    def setUp(self):
        self.examples_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "fixtures"))
        self.project_id = "ccaip-probing-infra-u8xi7u"
        self.location = "europe-west1"
        self.resource_id = "iva"

    def run_regression_test(self, fixture_name, expected_name, gcs_uri):
        fixture_path = os.path.join(self.examples_dir, fixture_name)
        expected_path = os.path.join(self.examples_dir, expected_name)

        # Load fixture metadata
        with open(fixture_path, "r") as f:
            metadata = json.load(f)

        # Load expected logs
        with open(expected_path, "r") as f:
            expected_logs = json.load(f)

        # Extract milestones
        extracted = extract_milestones(metadata, gcs_uri)
        
        # Format milestones as log entries
        actual_logs = [
            format_as_log_entry(
                m,
                project_id=self.project_id,
                location=self.location,
                resource_id=self.resource_id
            )
            for m in extracted
        ]

        # Verify exact match
        self.assertEqual(len(actual_logs), len(expected_logs), f"Mismatch in number of log entries for {fixture_name}")
        self.assertEqual(actual_logs, expected_logs, f"Parsed log entries differ from expected golden output for {fixture_name}")

    def test_call_1418_milestones(self):
        gcs_uri = "gs://ccaip-iva-artifact-9a/iva-prober-gxjs4ra.ew1/metadata/call-1418.json"
        self.run_regression_test("metadata_call-1418.json", "expected_logs_call-1418.json", gcs_uri)

    def test_call_987_milestones(self):
        gcs_uri = "gs://ccaip-iva-artifact-9a/iva-prober-gxjs4ra.ew1/metadata/call-987.json"
        self.run_regression_test("metadata_call-987.json", "expected_logs_call-987.json", gcs_uri)

    def test_chat_135_milestones(self):
        gcs_uri = "gs://ccaip-iva-artifact-9a/iva-prober-gxjs4ra.ew1/metadata/chat-135.json"
        self.run_regression_test("metadata_chat-135.json", "expected_logs_chat-135.json", gcs_uri)

if __name__ == "__main__":
    unittest.main()
