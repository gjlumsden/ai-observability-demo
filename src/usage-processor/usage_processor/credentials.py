def build_credential(client_id=None):
    from azure.identity import DefaultAzureCredential

    return DefaultAzureCredential(
        managed_identity_client_id=client_id,
        exclude_interactive_browser_credential=True,
    )
