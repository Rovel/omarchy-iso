"""Fresh installs use the Omarchy kernel, except for T2 Macs."""

import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402


class KernelSelectionTest(unittest.TestCase):
    def test_hardware_detection(self):
        # Run the configurator's actual probe without starting its disk wizard.
        configurator = (ROOT / "configs/airootfs/root/configurator").read_text()
        probe = re.search(r"^detect_kernel\(\) \{\n.*?^\}", configurator, re.M | re.S)
        self.assertIsNotNone(probe)
        cases = [
            ("00:02.0 VGA compatible controller [0300]: Intel [8086:b080]", "linux-omarchy"),
            ("00:01.0 Ethernet controller [0200]: Apple [106b:2001]", "linux-omarchy"),
            ("04:00.0 Mass storage controller [0180]: Apple [106b:1801]", "linux-t2"),
            ("04:00.0 Mass storage controller [0180]: Apple [106b:1802]", "linux-t2"),
            ("", "linux-omarchy"),
        ]
        for devices, expected in cases:
            with self.subTest(devices=devices):
                result = subprocess.run(
                    ["bash", "-c", 'lspci() { printf "%s\\n" "$TEST_PCI"; }\n'
                     + probe.group() + "\ndetect_kernel"],
                    env={**os.environ, "TEST_PCI": devices},
                    check=True, capture_output=True, text=True,
                )
                self.assertEqual(result.stdout.strip(), expected)

    def test_boot_validation_uses_default_or_explicit_kernel(self):
        for storage, configuration, expected in [
            ({}, {}, "linux-omarchy"),
            ({}, {"kernels": ["linux-t2"]}, "linux-t2"),
            ({"kernel": "linux-t2"}, {"kernels": ["linux-omarchy"]}, "linux-t2"),
            ({}, {"kernels": ["linux-lts"]}, "linux-lts"),
        ]:
            with self.subTest(kernel=expected, storage=storage), tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp)
                files = {
                    "boot/limine.conf": "/Omarchy\n",
                    "etc/kernel/cmdline": "root=UUID=test\n",
                    "etc/default/limine": "CUSTOM_UKI_NAME=omarchy\n",
                    "boot/EFI/limine/limine_x64.efi": "bootloader",
                    f"boot/EFI/Linux/omarchy_{expected}.efi": "UKI",
                }
                for name, content in files.items():
                    path = target / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content)
                ctx = types.SimpleNamespace(
                    target=target, omarchy_install={"storage": storage},
                    user_configuration=configuration, encrypt=False,
                    is_protected=False, defer_provisioning=False,
                )
                with mock.patch.object(phases_impl, "_assert_boot_hooks_restored"), \
                     mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True), \
                     mock.patch.object(phases_impl, "_read_efibootmgr", return_value={
                         "entries": {"0001": "Limine\tHD(1,GPT,test)"},
                     }):
                    phases_impl.validate_boot(ctx)
                    (target / f"boot/EFI/Linux/omarchy_{expected}.efi").unlink()
                    with self.assertRaisesRegex(RuntimeError, "missing or empty"):
                        phases_impl.validate_boot(ctx)


if __name__ == "__main__":
    unittest.main()
