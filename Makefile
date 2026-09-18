.PHONY: build test

build:
	cd lib/v2-core && FOUNDRY_CONFIG="$(CURDIR)/foundry.toml" forge build contracts/UniswapV2Factory.sol contracts/test/ERC20.sol --root . --profile core --skip-lint
	cd lib/v2-periphery && FOUNDRY_CONFIG="$(CURDIR)/foundry.toml" forge build contracts/UniswapV2Router02.sol contracts/test/WETH9.sol --root . --profile periphery --skip-lint

test: build
	forge test -vv
