#!/usr/bin/env python3
"""Deployment script regression checks with stubbed cast/forge/osascript.

临时工程根里放三个同名假命令，把 PATH 指过去，真脚本的调用被记入日志，
再对日志与退出码做断言。不碰真仓库、不碰真链。

用法：python3 test/deploy_scripts_test.py [<deploy-script-dir>]
默认被测目录为 script/deploy；传另一份拷贝可对比不同版本。
"""
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEX = Path(__file__).resolve().parents[1]
WBNB = "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd"
FACTORY = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
ROUTER = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
ZERO = "0x" + "0" * 40


def fake_tool(tool, args):
    data = json.loads(Path(os.environ["MOCK_DATA"]).read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([tool, *args] + [f"env:{k}={os.environ.get(k)}" for k in
                                              ("DEPLOY_TEST_WBNB", "WBNB_ADDRESS", "ADDRESSES_FILE")]) + "\n")
    if tool == "osascript":
        print("test-password")
    elif tool == "cast":
        if args[0] == "chain-id":
            print(os.environ.get("RPC_CHAIN", data["chain_id"]))
        elif args[0] == "call":
            key = args[1].lower() + "/" + args[2]
            print(data["calls"][key])
        else:
            raise AssertionError(args)
    elif tool == "forge":
        if os.environ.get("FORGE_FAIL"):
            return 1
        Path(os.environ["ADDRESSES_FILE"]).write_text(
            "WBNB_ADDRESS=" + data["deployed"]["wbnb"] + "\n"
            + "FACTORY_ADDRESS=" + data["deployed"]["factory"] + "\n"
            + "ROUTER_ADDRESS=" + data["deployed"]["router"] + "\n"
        )
    else:
        raise AssertionError(args)
    return 0


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else DEX / "script/deploy"
    print(f"# scripts under test: {source}")
    results = []
    with tempfile.TemporaryDirectory(prefix="dex-deploy-check-") as directory:
        root = Path(directory)
        shutil.copytree(source, root / "script/deploy")
        net = root / "script/network/test"
        net.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)

        calls = {
            WBNB.lower() + "/name()(string)": '"Wrapped BNB"',
            WBNB.lower() + "/symbol()(string)": '"WBNB"',
            FACTORY.lower() + "/feeTo()(address)": ZERO,
            FACTORY.lower() + "/feeToSetter()(address)": ZERO,
            ROUTER.lower() + "/factory()(address)": FACTORY,
            ROUTER.lower() + "/WETH()(address)": WBNB,
        }
        data_path, log_path = root / "rpc.json", root / "calls.log"
        deployed = {"wbnb": WBNB, "factory": FACTORY, "router": ROUTER}
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path)}
        script = root / "script/deploy"
        addresses = net / "addresses.dex.params"

        def set_data(call_overrides=None):
            data_path.write_text(json.dumps({"chain_id": "97", "calls": {**calls, **(call_overrides or {})},
                                             "deployed": deployed}))

        def fresh(account=True, params=None):
            set_data()
            for name, text in (params or {"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                                          "dex.params": "WBNB_ADDRESS=" + WBNB + "\n"}).items():
                (net / name).write_text(text)
            if account:
                (net / ".account").write_text("KEYSTORE_ACCOUNT=dev1\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\n")
            elif (net / ".account").exists():
                (net / ".account").unlink()
            addresses.unlink(missing_ok=True)

        def run(entry, *args, **extra):
            log_path.write_text("")
            proc = subprocess.run(["bash", str(script / entry), *args], env={**base, **extra},
                                  text=True, capture_output=True)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            return proc, log, [line for line in log if line[0] == "forge"], \
                [line for line in log if line[:2] == ["cast", "call"]], \
                [line for line in log if line[0] == "osascript"]

        def case(name, body):
            try:
                body()
                results.append((name, "PASS", ""))
            except AssertionError as error:
                results.append((name, "FAIL", str(error)[:900].replace("\n", " | ")))

        def one_click():
            fresh()
            proc, log, forge, calls_made, prompts = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert "✓ Deployment completed: test" in proc.stdout, proc.stdout
            assert addresses.read_text().startswith("WBNB_ADDRESS=" + WBNB), addresses.read_text()
            assert len(forge) == 1 and len(calls_made) == 6, log
            assert len(prompts) == 1, f"初始化应只弹一次密码: {log}"
            args = forge[0]
            assert "--account" in args and "--sender" in args and "test-password" in args, args
            assert "--broadcast" in args and "--legacy" in args and "--rpc-url" in args, args
            assert "env:DEPLOY_TEST_WBNB=false" in args, args
            assert "env:ADDRESSES_FILE=script/network/test/addresses.dex.params" in args, args
            assert "✓ Factory: " + FACTORY in proc.stdout, proc.stdout

        def step_not_entry():
            fresh()
            proc, log, forge, calls_made, prompts = run("01_deploy.sh", "test")
            assert proc.returncode != 0, "步骤单独执行应失败: " + proc.stdout
            assert not forge and not calls_made and not prompts, log

        def step_has_no_init():
            def code_lines(path):
                return [ln.strip() for ln in path.read_text().splitlines()
                        if ln.strip() and not ln.strip().startswith("#")]

            body = code_lines(script / "01_deploy.sh")
            assert not any("00_init" in ln for ln in body), body
            assert any("00_init" in ln and ln.startswith("source") for ln in code_lines(script / "one_click_deploy.sh")), \
                "拼装脚本应载入初始化"

        def check_standalone_real():
            fresh()
            proc, _, forge, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, proc.stdout
            (net / ".account").unlink()
            proc, log, forge, calls_made, prompts = run("99_check.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert not forge and not prompts, log
            assert len(calls_made) == 6, log
            assert "✓ Deployment verified" in proc.stdout, proc.stdout

        def testwbnb():
            fresh(params={"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                          "dex.params": "DEPLOY_TEST_WBNB=true\n"})
            set_data({WBNB.lower() + "/name()(string)": '"Wrapped Ether"',
                      WBNB.lower() + "/symbol()(string)": '"WETH"'})
            proc, _, _, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert "✓ Deployment verified" in proc.stdout, proc.stdout

        def bad_chain():
            fresh()
            proc, _, forge, _, _ = run("one_click_deploy.sh", "test", RPC_CHAIN="56")
            assert proc.returncode != 0, "rc=0; wrong chain accepted: " + proc.stdout
            assert not forge, "forge ran despite chain mismatch"

        def no_account():
            fresh(account=False)
            proc, _, forge, _, prompts = run("one_click_deploy.sh", "test")
            assert proc.returncode != 0, "rc=0; missing .account accepted: " + proc.stdout
            assert not forge and not prompts, "应在弹窗前失败"

        def no_network():
            fresh()
            proc, _, _, _, _ = run("one_click_deploy.sh")
            assert proc.returncode != 0, "rc=0; missing network accepted"
            proc, _, _, _, _ = run("99_check.sh", "nope")
            assert proc.returncode != 0, "rc=0; unknown network accepted"

        def no_addresses_file():
            fresh()
            proc, _, _, _, _ = run("99_check.sh", "test")
            assert proc.returncode != 0, "rc=0; check ran without addresses file: " + proc.stdout

        def inherited_env():
            fresh()
            proc, _, forge, _, _ = run("one_click_deploy.sh", "test",
                                       DEPLOY_TEST_WBNB="true", WBNB_ADDRESS="0x" + "de" * 20)
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            args = forge[0]
            assert "env:DEPLOY_TEST_WBNB=false" in args and "env:WBNB_ADDRESS=" + WBNB in args, args

        def reports_every_failure():
            fresh()
            run("one_click_deploy.sh", "test")
            set_data({FACTORY.lower() + "/feeTo()(address)": "0x" + "98" * 20,
                      ROUTER.lower() + "/WETH()(address)": "0x" + "97" * 20})
            proc, log, _, calls_made, _ = run("99_check.sh", "test")
            assert proc.returncode != 0, "rc=0; mismatches not reported"
            assert len(calls_made) == 6, "stopped early: " + str(log)
            assert proc.stdout.count("✗") == 2, proc.stdout
            assert "实际: 0x" + "98" * 20 in proc.stdout, proc.stdout
            assert "期望: 0x" + "0" * 40 in proc.stdout, proc.stdout
            assert "✗ 2 项不符" in proc.stderr, proc.stderr

        def forge_fails():
            fresh()
            addresses.write_text("# previous deployment\n")
            proc, _, _, calls_made, _ = run("one_click_deploy.sh", "test", FORGE_FAIL="1")
            assert proc.returncode != 0, "rc=0; forge failure ignored: " + proc.stdout
            assert addresses.read_text() == "# previous deployment\n", "stale addresses overwritten"
            assert not calls_made, "部署失败后不应继续复核"

        def preset_password():
            fresh()
            proc, _, forge, _, prompts = run("one_click_deploy.sh", "test", KEYSTORE_PASSWORD="preset-secret")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert not prompts, ("osascript called", prompts)
            assert "preset-secret" in forge[0], forge[0]

        case("01 拼装：一键 = 00+01+99，初始化只跑一次", one_click)
        case("02 编号步骤不是入口（裸跑即失败）", step_not_entry)
        case("03 步骤文件不含加载 init，由拼装脚本负责", step_has_no_init)
        case("04 复核步骤可独立跑（无 .account、无密码、不调 forge）", check_standalone_real)
        case("05 TestWBNB 模式（不填 WBNB_ADDRESS）", testwbnb)
        case("06 链 ID 不匹配即中止且不广播", bad_chain)
        case("07 缺 .account 即中止且不弹窗不广播", no_account)
        case("08 缺网络名 / 未知网络即中止", no_network)
        case("09 缺 addresses.dex.params 时复核非零退出", no_addresses_file)
        case("10 不串用调用者环境里的 DEPLOY_TEST_WBNB/WBNB_ADDRESS", inherited_env)
        case("11 复核把全部不符项都打出来（不中途退出）", reports_every_failure)
        case("12 forge 失败即非零退出且不覆盖旧地址、不复核", forge_fails)
        case("13 已设 KEYSTORE_PASSWORD 则不弹窗", preset_password)

        failed = sum(1 for _, status, _ in results if status == "FAIL")
        for name, status, detail in results:
            print(f"{status}  {name}" + (f"\n      {detail}" if detail else ""))
        print(f"# {len(results) - failed}/{len(results)} cases passed")
        return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    sys.exit(main())
