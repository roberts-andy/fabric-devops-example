import unittest
from scripts.parse_workspace_request import parse

BODY = """### Workspace name
SBX - Forecast

### Workspace key
forecast-team

### Sandbox type
team

### Owner principal type
Group

### Owner Entra object ID
11111111-1111-4111-8111-111111111111

### TTL in days
30

### Business purpose
Forecast experiment
"""

class RequestParserTests(unittest.TestCase):
    def test_parse_valid_request(self):
        value=parse(BODY)
        self.assertEqual(value["slug"],"forecast-team")
        self.assertEqual(value["ttl_days"],30)
    def test_team_requires_group(self):
        with self.assertRaisesRegex(ValueError,"require owner principal type Group"):
            parse(BODY.replace("### Owner principal type\nGroup","### Owner principal type\nUser"))
    def test_ttl_is_bounded(self):
        with self.assertRaisesRegex(ValueError,"between 1 and 90"):
            parse(BODY.replace("### TTL in days\n30","### TTL in days\n91"))
if __name__ == '__main__': unittest.main()
