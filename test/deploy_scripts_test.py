#!/usr/bin/env python3
"""Deployment regression checks with stubbed cast/forge/osascript.

临时工程根里放三个同名假命令，把 PATH 指过去，真脚本的调用被记入日志，
再对日志与退出码做断言。不碰真仓库、不碰真链。

用法：python3 test/deploy_scripts_test.py [<deploy-script-dir>]
默认被测目录为 script/deploy；传另一份拷贝可对比不同版本。
"""
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEX = Path(__file__).resolve().parents[1]
WETH = "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd"
FACTORY = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
ROUTER = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
ZERO = "0x" + "0" * 40


def fake_tool(tool, args):
    data = json.loads(Path(os.environ["MOCK_DATA"]).read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([tool, *args] + [f"env:{k}={os.environ.get(k)}" for k in
                                              ("WETH_ADDRESS", "ADDRESSES_FILE")]) + "\n")
    if tool == "osascript":
        print("test-password")
    elif tool == "cast":
        if args[0] == "chain-id":
            print(os.environ.get("RPC_CHAIN", data["chain_id"]))
        elif args[0] == "code":
            print("0x01")
        elif args[0] == "call":
            key = args[1].lower() + "/" + args[2]
            print(data["calls"][key])
        elif args[0] == "abi-encode":
            print("0x1234")
        else:
            raise AssertionError(args)
    elif tool == "mktemp":
        if "-d" in args:
            print(tempfile.mkdtemp(dir=os.environ["MOCK_TMP"]))
        else:
            fd, path = tempfile.mkstemp(dir=os.environ["MOCK_TMP"])
            os.close(fd)
            print(path)
    elif tool == "forge":
        if os.environ.get("FORGE_FAIL"):
            return 1
        if args[0] == "script":
            # 凭据哨兵：密码不得进进程参数；需要广播时密码文件必须已写入且非空。
            if "--password" in args:
                print("CREDENTIAL_IN_ARGV", file=sys.stderr)
            if "--broadcast" in args:
                password_file = args[args.index("--password-file") + 1] if "--password-file" in args else None
                if not password_file or not Path(password_file).is_file() or not Path(password_file).read_text():
                    print("PASSWORD_FILE_MISSING", file=sys.stderr)
                else:
                    print("PASSWORD_SHA=" + hashlib.sha256(Path(password_file).read_bytes()).hexdigest(),
                          file=sys.stderr)
                name = "DeployWETH" if "DeployWETH" in args[1] else "DeployUniswapV2"
                artifact = Path(os.environ["MOCK_BROADCAST_ROOT"]) / f"{name}.s.sol" / "97" / "run-latest.json"
                artifact.parent.mkdir(parents=True, exist_ok=True)
                artifact.write_text(json.dumps({"timestamp": int(time.time() * 1000)}))
            target = Path(os.environ["ADDRESSES_FILE"])
            if "DeployWETH" in args[1]:
                target.write_text("WETH_ADDRESS=" + data["deployed"]["weth"] + "\n")
            else:
                target.write_text("FACTORY_ADDRESS=" + data["deployed"]["factory"] + "\n"
                                  + "ROUTER_ADDRESS=" + data["deployed"]["router"] + "\n")
        elif args[0] == "verify-contract" and os.environ.get("VERIFY_FAIL") == args[2]:
            return 1
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
        for tool in ("cast", "forge", "osascript", "mktemp"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)

        calls = {
            WETH.lower() + "/name()(string)": '"Wrapped BNB"',
            WETH.lower() + "/symbol()(string)": '"WBNB"',
            WETH.lower() + "/decimals()(uint8)": "18",
            WETH.lower() + "/deposit()": "",
            WETH.lower() + "/withdraw(uint256)": "",
            FACTORY.lower() + "/feeTo()(address)": ZERO,
            FACTORY.lower() + "/feeToSetter()(address)": ZERO,
            ROUTER.lower() + "/factory()(address)": FACTORY,
            ROUTER.lower() + "/WETH()(address)": WETH,
        }
        data_path, log_path = root / "rpc.json", root / "calls.log"
        tmp_dir = root / "tmp"
        tmp_dir.mkdir()
        deployed = {"weth": WETH, "factory": FACTORY, "router": ROUTER}
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path), "MOCK_TMP": str(tmp_dir), "MOCK_BROADCAST_ROOT": str(root / "broadcast"),
                "ETHERSCAN_API_KEY": "test-key"}
        script = root / "script/deploy"
        weth_file = net / "addresses.weth.params"
        uni_file = net / "addresses.uniswapv2.params"

        def set_data(call_overrides=None):
            data_path.write_text(json.dumps({"chain_id": "97", "calls": {**calls, **(call_overrides or {})},
                                             "deployed": deployed}))

        def fresh(account=True, params=None):
            set_data()
            for name, text in (params or {"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                                          "dex.params": "WETH_ADDRESS=" + WETH + "\n"}).items():
                (net / name).write_text(text)
            if account:
                (net / ".account").write_text("KEYSTORE_ACCOUNT=dev1\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\n")
            elif (net / ".account").exists():
                (net / ".account").unlink()
            weth_file.unlink(missing_ok=True)
            uni_file.unlink(missing_ok=True)

        def run(entry, *args, **extra):
            log_path.write_text("")
            proc = subprocess.run(["bash", str(script / entry), *args], env={**base, **extra},
                                  text=True, capture_output=True)
            output = proc.stdout + proc.stderr
            for marker in ("CREDENTIAL_IN_ARGV", "PASSWORD_FILE_MISSING"):
                assert marker not in output, (marker, output)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            forge = [line for line in log if line[0] == "forge"]
            for call in forge:
                if call[:2] == ["forge", "script"] and "--password-file" in call:
                    assert not Path(call[call.index("--password-file") + 1]).exists(), call
            return proc, log, forge, \
                [line for line in log if line[:2] == ["cast", "call"]], \
                [line for line in log if line[0] == "osascript"]

        def script_call(log, contract):
            return next(call for call in log if call[:2] == ["forge", "script"] and contract in call[2])

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
            scripts = [call for call in log if call[:2] == ["forge", "script"]]
            # 外部 WETH 模式：WETH 步骤只做只读模拟校验，UniswapV2 一笔广播。
            assert len(scripts) == 2, log
            weth_call = script_call(log, "DeployWETH")
            assert "--broadcast" not in weth_call and "--account" not in weth_call, weth_call
            uni_call = script_call(log, "DeployUniswapV2")
            assert "--account" in uni_call and "--sender" in uni_call and "--password-file" in uni_call, uni_call
            assert "--broadcast" in uni_call and "--legacy" in uni_call, uni_call
            # 入口只解析一次 keystore 密码并导出，UniswapV2 步骤沿用。
            assert len(prompts) == 1, f"keystore 密码应只弹一次窗: {log}"
            assert weth_file.read_text().startswith("WETH_ADDRESS=" + WETH), weth_file.read_text()
            assert uni_file.read_text().startswith("FACTORY_ADDRESS=" + FACTORY), uni_file.read_text()
            assert "Using external WETH: " + WETH in proc.stdout, proc.stdout
            assert "✓ Factory: " + FACTORY in proc.stdout, proc.stdout
            assert "✓ WETH verified" in proc.stdout and "✓ UniswapV2 verified" in proc.stdout, proc.stdout
            assert "✓ Source verification succeeded for Factory and Router02" in proc.stdout, proc.stdout
            # 外部 WETH：接口校验在 DeployWETH.s.sol 模拟中完成，21 复核 decimals/deposit/withdraw
            # 三项，22 复核 Factory 两项 + Router 两项。
            assert len(calls_made) == 7, log
            assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())

        def module_order():
            # 编号即依赖顺序：deploy 1x / check 2x / verify 3x；WETH 模块（11/21/31）在前，UniswapV2 模块（12/22/32）在后。
            def number(name):
                return int(name.split("_", 1)[0])

            names = [p.name for p in script.glob("*.sh")]
            assert number("11_deploy_weth.sh") < number("12_deploy_uniswapv2.sh"), names
            assert number("21_check_weth.sh") < number("22_check_uniswapv2.sh"), names
            assert number("31_verify_weth.sh") < number("32_verify.sh"), names

        def step_requires_network():
            fresh()
            proc, log, forge, calls_made, prompts = run("11_deploy_weth.sh")
            assert proc.returncode != 0, "步骤缺参应失败: " + proc.stdout
            assert not forge and not calls_made and not prompts, log

        def step_standalone():
            # 自包含：每个模块的部署步骤带网络名即可独立跑通。
            fresh()
            proc, _, forge, _, _ = run("11_deploy_weth.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert len(forge) == 1 and "DeployWETH" in forge[0][2], forge
            assert "--broadcast" not in forge[0], forge
            assert "Using external WETH: " + WETH in proc.stdout, proc.stdout
            assert weth_file.read_text().startswith("WETH_ADDRESS=" + WETH), weth_file.read_text()
            proc, _, forge, _, _ = run("12_deploy_uniswapv2.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert len(forge) == 1 and "DeployUniswapV2" in forge[0][2], forge
            assert uni_file.read_text().startswith("FACTORY_ADDRESS=" + FACTORY), uni_file.read_text()
            assert "✓ Router02: " + ROUTER in proc.stdout, proc.stdout

        def uniswapv2_requires_weth_file():
            fresh()
            proc, _, forge, _, _ = run("12_deploy_uniswapv2.sh", "test")
            assert proc.returncode != 0, "缺少 addresses.weth.params 应失败: " + proc.stdout
            assert not forge, "WETH 模块未就绪不应广播"
            assert "11_deploy_weth.sh" in proc.stdout + proc.stderr, proc.stdout + proc.stderr

        def step_has_no_init():
            def code_lines(path):
                return [ln.strip() for ln in path.read_text().splitlines()
                        if ln.strip() and not ln.strip().startswith("#")]

            for name in ("11_deploy_weth.sh", "12_deploy_uniswapv2.sh", "21_check_weth.sh",
                         "22_check_uniswapv2.sh", "31_verify_weth.sh", "32_verify.sh", "one_click_deploy.sh"):
                assert not any("00_init" in ln for ln in code_lines(script / name)), name
            entry = code_lines(script / "one_click_deploy.sh")
            assert not any(ln.startswith("source") for ln in entry), "入口不应 source 任何文件"
            assert any(ln.startswith("source") for ln in code_lines(script / "11_deploy_weth.sh")), "步骤应自行载入配置"

        def check_standalone_real():
            fresh()
            proc, _, _, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, proc.stdout
            (net / ".account").unlink()
            proc, log, forge, calls_made, prompts = run("21_check_weth.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert not forge and not prompts, log
            proc, log, forge, calls_made, prompts = run("22_check_uniswapv2.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert not forge and not prompts, log
            assert "✓ UniswapV2 verified" in proc.stdout, proc.stdout

        def local_deploy_mode():
            # 不配置 WETH_ADDRESS：WETH_NAME + WETH_SYMBOL 本地部署可配置 WETH。
            fresh(params={"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                          "dex.params": 'WETH_NAME="Test Wrapped ETH"\nWETH_SYMBOL=TestWETH\n'})
            set_data({WETH.lower() + "/name()(string)": '"Test Wrapped ETH"',
                      WETH.lower() + "/symbol()(string)": '"TestWETH"'})
            proc, _, _, calls_made, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert "✓ WETH verified" in proc.stdout, proc.stdout
            assert '✓ WETH 名称 = "Test Wrapped ETH"' in proc.stdout, proc.stdout
            assert '✓ WETH 符号 = "TestWETH"' in proc.stdout, proc.stdout
            assert len(calls_made) == 9, calls_made  # WETH 名称/符号 + 接口三项 + Factory 两项 + Router 两项

        def key_set_mismatch():
            # 键名漏改（如历史 WBNB_ADDRESS→WETH_ADDRESS 漏改）必须显式失败。
            fresh()
            run("one_click_deploy.sh", "test")
            weth_file.write_text("WBNB_ADDRESS=" + WETH + "\n")
            proc, _, _, _, _ = run("21_check_weth.sh", "test")
            assert proc.returncode != 0, "键集合不符应失败: " + proc.stdout
            assert "key set mismatch" in proc.stdout + proc.stderr, proc.stdout + proc.stderr
            uni_file.write_text("FACTORY_ADDRESS=" + FACTORY + "\nROUTER02_ADDRESS=" + ROUTER + "\n")
            proc, _, _, _, _ = run("22_check_uniswapv2.sh", "test")
            assert proc.returncode != 0, "键集合不符应失败: " + proc.stdout
            assert "key set mismatch" in proc.stdout + proc.stderr, proc.stdout + proc.stderr

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
            proc, _, _, _, _ = run("21_check_weth.sh", "nope")
            assert proc.returncode != 0, "rc=0; unknown network accepted"

        def no_addresses_file():
            fresh()
            proc, _, _, _, _ = run("21_check_weth.sh", "test")
            assert proc.returncode != 0, "rc=0; check ran without addresses file: " + proc.stdout

        def inherited_env():
            fresh()
            proc, _, forge, _, _ = run("one_click_deploy.sh", "test", WETH_ADDRESS="0x" + "de" * 20)
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            weth_call = script_call(log, "DeployWETH")
            assert "--broadcast" not in weth_call, weth_call
            assert "env:WETH_ADDRESS=" + WETH in script_call(log, "DeployUniswapV2"), script_call(log, "DeployUniswapV2")
            assert weth_file.read_text().startswith("WETH_ADDRESS=" + WETH), weth_file.read_text()

        def reports_every_failure():
            fresh()
            run("one_click_deploy.sh", "test")
            set_data({FACTORY.lower() + "/feeTo()(address)": "0x" + "98" * 20,
                      ROUTER.lower() + "/WETH()(address)": "0x" + "97" * 20})
            proc, log, _, calls_made, _ = run("22_check_uniswapv2.sh", "test")
            assert proc.returncode != 0, "rc=0; mismatches not reported"
            assert proc.stdout.count("✗") == 2, proc.stdout
            assert "实际: 0x" + "98" * 20 in proc.stdout, proc.stdout
            assert "✗ 2 项不符" in proc.stderr, proc.stderr

        def forge_fails():
            fresh()
            weth_file.write_text("# previous deployment\n")
            uni_file.write_text("# previous deployment\n")
            proc, _, _, calls_made, _ = run("one_click_deploy.sh", "test", FORGE_FAIL="1")
            assert proc.returncode != 0, "rc=0; forge failure ignored: " + proc.stdout
            # 外部 WETH 的 Solidity 模拟校验失败，两个地址文件都保持原样。
            assert weth_file.read_text() == "# previous deployment\n", weth_file.read_text()
            assert uni_file.read_text() == "# previous deployment\n", "stale addresses overwritten"
            assert calls_made == [], "部署失败后不应继续复核"

            assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())

        def check_failure_rolls_back_both_files():
            fresh()
            run("one_click_deploy.sh", "test")
            weth_file.write_text("# previous weth\n")
            uni_file.write_text("# previous uni\n")
            set_data({FACTORY.lower() + "/feeTo()(address)": "0x" + "98" * 20})
            proc, _, _, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode != 0, "rc=0; check failure ignored"
            assert weth_file.read_text() == "# previous weth\n", weth_file.read_text()
            assert uni_file.read_text() == "# previous uni\n", uni_file.read_text()
            assert "previously saved addresses were restored" in proc.stdout, proc.stdout

        def preset_password():
            # .account 配了非空 KEYSTORE_PASSWORD：入口直接沿用，不弹窗。
            fresh()
            (net / ".account").write_text("KEYSTORE_ACCOUNT=dev1\nACCOUNT_ADDRESS=0x" + "f5" * 20
                                          + "\nKEYSTORE_PASSWORD=preset-secret\n")
            proc, _, _, _, prompts = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert not prompts, ("osascript called", prompts)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            assert "--password-file" in script_call(log, "DeployUniswapV2")
            assert "PASSWORD_SHA=" + hashlib.sha256(b"preset-secret").hexdigest() in proc.stdout + proc.stderr, \
                proc.stdout + proc.stderr

        def entry_resets_inherited_password():
            # 入口先重置：调用方环境里的旧密码不静默复用，改由 .account 或一次性交互提供。
            fresh()
            proc, _, _, _, prompts = run("one_click_deploy.sh", "test", KEYSTORE_PASSWORD="stale-secret")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert len(prompts) == 1, f"旧密码应被重置并重新获取: {log_path.read_text()}"
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            output = proc.stdout + proc.stderr
            assert "PASSWORD_SHA=" + hashlib.sha256(b"stale-secret").hexdigest() not in output, output
            assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in output, output

        def verify_on_bsc():
            fresh()
            proc, log, forge, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, proc.stdout + proc.stderr
            verifies = [call for call in log if call[1] == "verify-contract"]
            assert len(verifies) == 2, verifies
            joined = " ".join(str(call) for call in verifies)
            assert "lib/v2-core/contracts/UniswapV2Factory.sol:UniswapV2Factory" in joined, joined
            assert "lib/v2-periphery/contracts/UniswapV2Router02.sol:UniswapV2Router02" in joined, joined
            assert joined.count("--constructor-args") == 2, joined
            # 官方 WETH 不是本仓库部署的合约，不按本地 WETH9 源提交验证。
            assert "WETH9" not in joined, joined

        def verify_skips_local_chain():
            fresh()
            proc, _, _, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, proc.stdout
            (net / "network.params").write_text("CHAIN_ID=31337\nRPC_URL=http://invalid.local\n")
            proc, log, forge, _, _ = run("32_verify.sh", "test")
            assert proc.returncode == 0, proc.stdout + proc.stderr
            assert not forge, log
            assert "Skip" in proc.stdout, proc.stdout

        def verify_needs_api_key():
            fresh()
            proc, _, forge, _, _ = run("one_click_deploy.sh", "test", ETHERSCAN_API_KEY="")
            assert proc.returncode != 0, "缺少 API Key 应失败: " + proc.stdout
            assert not any(call[1] == "verify-contract" for call in forge), forge

        def external_weth_needs_no_account():
            fresh(account=False)
            proc, _, forge, calls_made, _ = run("11_deploy_weth.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert len(forge) == 1 and "DeployWETH" in forge[0][2], forge
            assert "--broadcast" not in forge[0], forge
            assert calls_made == [], calls_made
            assert "Using external WETH: " + WETH in proc.stdout, proc.stdout
            assert weth_file.read_text().startswith("WETH_ADDRESS=" + WETH), weth_file.read_text()

        def local_weth_requires_account():
            fresh(account=False, params={"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                                         "dex.params": 'WETH_NAME="Test Wrapped ETH"\nWETH_SYMBOL=TestWETH\n'})
            proc, _, forge, _, prompts = run("11_deploy_weth.sh", "test")
            output = proc.stdout + proc.stderr
            assert proc.returncode != 0, "本地 WETH 缺 .account 应失败: " + output
            assert "Missing required configuration" in output, output
            assert not forge and not prompts, (forge, prompts)

        def weth_check_rejects_combination():
            fresh(params={"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                          "dex.params": "WETH_ADDRESS=" + WETH
                          + '\nWETH_NAME="Test Wrapped ETH"\nWETH_SYMBOL=TestWETH\n'})
            weth_file.write_text("WETH_ADDRESS=" + WETH + "\n")
            proc, _, _, calls_made, _ = run("21_check_weth.sh", "test")
            output = proc.stdout + proc.stderr
            assert proc.returncode != 0, "复核应拒绝同时配置地址与名称/符号: " + output
            assert "mutually exclusive" in output, output
            assert not calls_made, calls_made

        def weth_check_address_mismatch():
            fresh()
            weth_file.write_text("WETH_ADDRESS=0x" + "99" * 20 + "\n")
            proc, _, _, calls_made, _ = run("21_check_weth.sh", "test")
            output = proc.stdout + proc.stderr
            assert proc.returncode != 0, "地址文件与 dex.params 不一致应失败: " + output
            assert "does not match dex.params WETH_ADDRESS" in output, output
            assert not calls_made, calls_made

        case("01 拼装：一键 = 11+12+21+22+31+32，入口只弹一次窗", one_click)
        case("02 编号即依赖顺序：WETH 在前，UniswapV2 在后", module_order)
        case("03 步骤缺网络名即失败", step_requires_network)
        case("04 两模块部署步骤各自独立跑通", step_standalone)
        case("05 UniswapV2 模块要求 WETH 模块先就绪", uniswapv2_requires_weth_file)
        case("06 无 00_init：入口不 source、步骤自行载入", step_has_no_init)
        case("07 复核步骤可独立跑（无 .account、无密码、不调 forge）", check_standalone_real)
        case("08 本地部署 WETH 模式（不配置 WETH_ADDRESS）", local_deploy_mode)
        case("09 地址文件键集合不符即显式失败", key_set_mismatch)
        case("10 链 ID 不匹配即中止且不广播", bad_chain)
        case("11 缺 .account 即中止且不弹窗不广播", no_account)
        case("12 缺网络名 / 未知网络即中止", no_network)
        case("13 缺 addresses.weth.params 时复核非零退出", no_addresses_file)
        case("14 不串用调用者环境里的 WETH_ADDRESS", inherited_env)
        case("15 复核把全部不符项都打出来（不中途退出）", reports_every_failure)
        case("16 forge 失败即非零退出且不覆盖旧地址、不复核", forge_fails)
        case("17 校验失败回滚两个模块的地址文件", check_failure_rolls_back_both_files)
        case("18 已设 KEYSTORE_PASSWORD（.account）则不弹窗", preset_password)
        case("19 入口重置调用方环境里的旧密码", entry_resets_inherited_password)
        case("20 BSC 链验证 Factory 与 Router02（含构造参数，不验官方 WETH）", verify_on_bsc)
        case("21 本地链跳过开源验证", verify_skips_local_chain)
        case("22 缺 ETHERSCAN_API_KEY 即失败且不验证", verify_needs_api_key)
        case("23 外部 WETH 模式不需要 .account", external_weth_needs_no_account)
        case("24 本地 WETH 模式缺 .account 即中止", local_weth_requires_account)
        case("25 复核拒绝地址与 name/symbol 同时配置", weth_check_rejects_combination)
        case("26 外部地址文件与 dex.params 不一致即失败", weth_check_address_mismatch)

        failed = sum(1 for _, status, _ in results if status == "FAIL")
        for name, status, detail in results:
            print(f"{status}  {name}" + (f"\n      {detail}" if detail else ""))
        print(f"# {len(results) - failed}/{len(results)} cases passed")
        return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    sys.exit(main())
