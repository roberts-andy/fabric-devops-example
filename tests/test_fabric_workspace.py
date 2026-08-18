import json, tempfile, unittest
from pathlib import Path
from unittest.mock import Mock
from scripts.fabric_workspace import FabricClient, FabricError, GitTarget, delete

BASE="https://api.fabric.microsoft.com/v1"
WS="11111111-1111-4111-8111-111111111111"
CONN="22222222-2222-4222-8222-222222222222"

class FakeResponse:
    def __init__(self,status=200,payload=None,headers=None):
        self.status_code=status; self._payload=payload or {}; self.headers=headers or {}
        self.content=json.dumps(self._payload).encode() if payload is not None else b''
        self.text=self.content.decode()
    def json(self): return self._payload

class FabricTests(unittest.TestCase):
    def test_connect_github_uses_configured_connection(self):
        client=FabricClient("token")
        client.session.request=Mock(side_effect=[
            FakeResponse(payload={"gitProviderDetails":None,"gitConnectionState":"NotConnected"}),
            FakeResponse(payload={})])
        changed=client.ensure_git_connection(WS,GitTarget("contoso","fabric-platform","main","sandboxes/demo/fabric",CONN))
        self.assertTrue(changed)
        body=client.session.request.call_args_list[1].kwargs['json']
        self.assertEqual(body['gitProviderDetails']['gitProviderType'],'GitHub')
        self.assertEqual(body['myGitCredentials'],{"source":"ConfiguredConnection","connectionId":CONN})
    def test_mismatched_git_target_is_rejected(self):
        client=FabricClient("token")
        client.session.request=Mock(return_value=FakeResponse(payload={"gitProviderDetails":{"gitProviderType":"GitHub","ownerName":"other","repositoryName":"repo","branchName":"main","directoryName":"x"},"gitConnectionState":"ConnectedAndInitialized"}))
        with self.assertRaisesRegex(FabricError,"different Git target"):
            client.ensure_git_connection(WS,GitTarget("contoso","fabric-platform","main","sandboxes/demo/fabric",CONN))
    def test_shortcut_is_create_or_overwrite(self):
        lake="33333333-3333-4333-8333-333333333333"
        client=FabricClient("token"); client.session.request=Mock(return_value=FakeResponse(status=201,payload={"name":"curated"}))
        client.apply_shortcuts(WS,lake,[{"name":"curated","path":"Files/shared","target":{"oneLake":{"workspaceId":WS,"itemId":lake,"path":"Tables/x"}}}])
        url=client.session.request.call_args.args[1]
        self.assertTrue(url.endswith('/shortcuts?shortcutConflictPolicy=CreateOrOverwrite'))
    def test_delete_rejects_managed_registry(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'managed.json'; path.write_text(json.dumps({"lifecycle":"managed","workspace_id":WS,"display_name":"Prod"}))
            class A: registry=str(path); workspace_id=WS; expected_display_name='Prod'; output=None; base_url=BASE
            with self.assertRaisesRegex(ValueError,'not sandbox'): delete(A())
if __name__ == '__main__': unittest.main()
