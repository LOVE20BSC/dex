#!/usr/bin/env python3
"""Deployment regression checks with stubbed cast/forge/osascript.

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
            if os.environ.get("RPC_CODE_ERROR"):
                return 1
            print("0x01")
        elif args[0] == "call":
            key = args[1].lower() + "/" + args[2]
            print(data["calls"][key])
        elif args[0] == "abi-encode":
            print("0x1234")
        else:
            raise AssertionError(args)
    elif tool == "forge":
        if os.environ.get("FORGE_FAIL"):
            return 1
        if args[0] == "script":
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
        for tool in ("cast", "forge", "osascript"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)

        calls = {
            WETH.lower() + "/name()(string)": '"Wrapped BNB"',
            WETH.lower() + "/symbol()(string)": '"WBNB"',
            FACTORY.lower() + "/feeTo()(address)": ZERO,
            FACTORY.lower() + "/feeToSetter()(address)": ZERO,
            ROUTER.lower() + "/factory()(address)": FACTORY,
            ROUTER.lower() + "/WETH()(address)": WETH,
        }
        data_path, log_path = root / "rpc.json", root / "calls.log"
        deployed = {"weth": WETH, "factory": FACTORY, "router": ROUTER}
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path), "ETHERSCAN_API_KEY": "test-key"}
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
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            return proc, log, [line for line in log if line[0] == "forge"], \
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
            assert len(scripts) == 2, log
            weth_call = script_call(log, "DeployWETH")
            uni_call = script_call(log, "DeployUniswapV2")
            for call in (weth_call, uni_call):
                assert "--account" in call and "--sender" in call and "test-password" in call, call
                assert "--broadcast" in call and "--legacy" in call, call
            # 入口只解析一次 keystore 密码并导出，两个部署模块沿用，不重复弹窗。
            assert len(prompts) == 1, f"keystore 密码应只弹一次窗: {log}"
            assert weth_file.read_text().startswith("WETH_ADDRESS=" + WETH), weth_file.read_text()
            assert uni_file.read_text().startswith("FACTORY_ADDRESS=" + FACTORY), uni_file.read_text()
            assert "✓ WETH: " + WETH in proc.stdout, proc.stdout
            assert "✓ Factory: " + FACTORY in proc.stdout, proc.stdout
            assert "✓ WETH verified" in proc.stdout and "✓ UniswapV2 verified" in proc.stdout, proc.stdout
            assert "✓ Source verification succeeded for Factory and Router02" in proc.stdout, proc.stdout
            assert len(calls_made) == 6, log  # WETH 名称/符号 + Factory 两项 + Router 两项

        def module_order():
            # 编号即依赖顺序：deploy 1x / check 2x / verify 3x；WETH 模块（11/21）在前，UniswapV2 模块（12/22/32）在后。
            def number(name):
                return int(name.split("_", 1)[0])

            names = [p.name for p in script.glob("*.sh")]
            assert number("11_deploy_weth.sh") < number("12_deploy_uniswapv2.sh"), names
            assert number("21_check_weth.sh") < number("22_check_uniswapv2.sh"), names

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
                         "22_check_uniswapv2.sh", "32_verify.sh", "one_click_deploy.sh"):
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
            # 不配置 WETH_ADDRESS：WETH 模块本地部署上游 WETH9（链上名称 Wrapped Ether）。
            fresh(params={"network.params": "CHAIN_ID=97\nRPC_URL=http://invalid.local\n",
                          "dex.params": ""})
            set_data({WETH.lower() + "/name()(string)": '"Wrapped Ether"',
                      WETH.lower() + "/symbol()(string)": '"WETH"'})
            proc, _, _, _, _ = run("one_click_deploy.sh", "test")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert "✓ WETH verified" in proc.stdout, proc.stdout

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
            proc, _, _, _, _ = run("one_click_deploy.sh", "test", WETH_ADDRESS="0x" + "de" * 20)
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            assert "env:WETH_ADDRESS=" + WETH in script_call(log, "DeployWETH"), script_call(log, "DeployWETH")

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
            assert weth_file.read_text() == "# previous deployment\n", "stale addresses overwritten"
            assert uni_file.read_text() == "# previous deployment\n", "stale addresses overwritten"
            assert not calls_made, "部署失败后不应继续复核"

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
            assert "preset-secret" in script_call(log, "DeployWETH")
            assert "preset-secret" in script_call(log, "DeployUniswapV2")

        def entry_resets_inherited_password():
            # 入口先重置：调用方环境里的旧密码不静默复用，改由 .account 或一次性交互提供。
            fresh()
            proc, _, _, _, prompts = run("one_click_deploy.sh", "test", KEYSTORE_PASSWORD="stale-secret")
            assert proc.returncode == 0, f"rc={proc.returncode} " + proc.stdout + proc.stderr
            assert len(prompts) == 1, f"旧密码应被重置并重新获取: {log_path.read_text()}"
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            assert "stale-secret" not in str(script_call(log, "DeployWETH")), script_call(log, "DeployWETH")
            assert "test-password" in script_call(log, "DeployWETH"), script_call(log, "DeployWETH")

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

        def configured_weth_must_be_deployed():
            fresh()
            proc, log, forge, _, _ = run("one_click_deploy.sh", "test", RPC_CODE_ERROR="1")
            assert proc.returncode != 0, "配置的 WETH 不是已部署合约时应失败: " + proc.stdout
            assert not forge, "WETH 校验失败不应广播"
            assert "WETH_ADDRESS" in proc.stdout + proc.stderr, proc.stdout + proc.stderr

        case("01 拼装：一键 = 11+12+21+22+32，入口只弹一次窗", one_click)
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
        case("23 配置的 WETH 不是已部署合约即中止", configured_weth_must_be_deployed)

        failed = sum(1 for _, status, _ in results if status == "FAIL")
        for name, status, detail in results:
            print(f"{status}  {name}" + (f"\n      {detail}" if detail else ""))
        print(f"# {len(results) - failed}/{len(results)} cases passed")
        return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    sys.exit(main())
