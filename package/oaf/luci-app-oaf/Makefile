include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for OAF
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+appfilter +kmod-oaf +luci-compat +luci-lib-jsonc

PKG_NAME:=luci-app-oaf
PKG_VERSION:=7.0
PKG_RELEASE:=2
# 本目录是 vendored 进来的，没有 po/ 的 git 历史，luci.mk 的 findrev 会得到 0。
# 显式给翻译包一个稳定版本号。
PKG_PO_VERSION:=7.0.2

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
