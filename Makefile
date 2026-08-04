ANSIBLE_DIR := ansible
PLAYBOOK    := site.yml
LIMIT       ?= all

.DEFAULT_GOAL := help

.PHONY: help
help: ## このヘルプを表示
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: check
check: ## 差分だけ確認する（変更を加えない）
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) --limit $(LIMIT) --check --diff

.PHONY: apply
apply: ## 構築・収束させる
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) --limit $(LIMIT)

.PHONY: image
image: ## ゴールデンイメージを作り直す（エージェント CLI を最新化したいとき）
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) --limit $(LIMIT) \
		--tags image -e force_image_rebuild=true

.PHONY: ping
ping: ## 疎通確認
	cd $(ANSIBLE_DIR) && ansible $(LIMIT) -m ping

.PHONY: lint
lint: ## 構文チェック
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) --syntax-check
	shellcheck image/build-dev-base.sh || true
