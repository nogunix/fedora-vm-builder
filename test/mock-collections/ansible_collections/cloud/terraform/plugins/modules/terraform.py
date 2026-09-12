"""Mock cloud.terraform.terraform module for CI task-coverage runs."""

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec={
            "project_path": {"type": "str", "required": True},
            "binary_path": {"type": "str", "default": "terraform"},
            "state": {"type": "str", "default": "present", "choices": ["present", "absent"]},
            "force_init": {"type": "bool", "default": False},
            "variables": {"type": "dict", "default": {}},
            "variables_files": {"type": "list", "elements": "str", "default": []},
            "plan_file": {"type": "str", "default": ""},
            "lock": {"type": "bool", "default": True},
            "targets": {"type": "list", "elements": "str", "default": []},
            "workspace": {"type": "str", "default": "default"},
            "check_destroy": {"type": "bool", "default": False},
            "parallelism": {"type": "int", "default": 10},
            "provider_upgrade": {"type": "bool", "default": False},
            "overwrite_init": {"type": "bool", "default": True},
            "init_reconfigure": {"type": "bool", "default": False},
            "backend_config": {"type": "dict", "default": {}},
            "backend_config_files": {"type": "list", "elements": "str", "default": []},
            "plugin_paths": {"type": "list", "elements": "str", "default": []},
            "complex_vars": {"type": "bool", "default": False},
        },
        supports_check_mode=True,
    )

    state = module.params["state"]

    if state == "present":
        module.exit_json(
            changed=True,
            outputs={
                "vm_ip": {"value": "127.0.0.1", "type": "string", "sensitive": False},
                "vm_name": {"value": "fedora01_vm0", "type": "string", "sensitive": False},
            },
            stdout="Apply complete! Resources: 4 added, 0 changed, 0 destroyed.",
            command="tofu apply",
        )
    else:
        module.exit_json(
            changed=True,
            outputs={},
            stdout="Destroy complete! Resources: 4 destroyed.",
            command="tofu destroy",
        )


if __name__ == "__main__":
    main()
