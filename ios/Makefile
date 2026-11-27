shots:
	scripts/shots.sh ../docs/screenshots/s11

shots-s15:
	scripts/shots-s15.sh ../docs/screenshots/s15

.PHONY: shots shots-s15 shots-s14 shots-s16 shots-s17 shots-s18 shots-s19 shots-s20 shots-s21 shots-scan-layout store-shots archive-check

shots-s14:
	scripts/shots-s14.sh ../docs/screenshots/s14

shots-s16:
	scripts/shots-s16.sh ../docs/screenshots/s16

shots-s17:
	scripts/shots-s17.sh ../docs/screenshots/s17

shots-s18:
	scripts/shots-s18.sh ../docs/screenshots/s18

shots-s19:
	scripts/shots-s19.sh ../docs/screenshots/s19

shots-s20:
	scripts/shots-s20.sh ../docs/screenshots/s20

shots-s21:
	scripts/shots-s21.sh ../docs/screenshots/s21

shots-scan-layout:
	scripts/shots-scan-layout.sh ../docs/screenshots/scan-layout

# S30 商店截图：6.9 寸、6.5 寸各 6 张（演示小店、审核号，本机临时服务端）
store-shots:
	scripts/store-shots.sh ../docs/appstore/screenshots

# S30 Release 归档检查：make archive-check ARCHIVE=/path/to/YH.xcarchive（也认 .ipa、.app）
archive-check:
	@test -n "$(ARCHIVE)" || { echo "用法：make archive-check ARCHIVE=<.xcarchive|.ipa|.app>"; exit 2; }
	scripts/archive-check.sh "$(ARCHIVE)"
