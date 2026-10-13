# code-master:title win-box · romtool · 构建
#
# 契约：docs/interfaces/03-romtool.md
# 目标：make / make test / make install（PREFIX=~/.local）
# 无第三方依赖：只用 libc + POSIX。

CC      ?= cc
PREFIX  ?= $(HOME)/.local
DESTDIR ?=
CFLAGS  ?= -std=c99 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L

BIN     := romtool
TESTBIN := tests/mkrom
OBJS    := romtool.o rom.o sha256.o
TESTDIR := tests

.PHONY: all test install uninstall clean check-synthetic

all: $(BIN) $(TESTBIN)

$(BIN): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

%.o: %.c rom.h sha256.h
	$(CC) $(CFLAGS) -c -o $@ $<

$(TESTBIN): $(TESTDIR)/mkrom.c rom.o sha256.o
	$(CC) $(CFLAGS) -I. -o $@ $(TESTDIR)/mkrom.c rom.o sha256.o

# make test：用**源码生成的合成 ROM**做断言，不需要任何硬件、
# 也不含任何 AMD 二进制（这是能把 C 工具放进公开仓库的前提）
test: all
	@sh $(TESTDIR)/run.sh

install: $(BIN)
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 $(BIN) "$(DESTDIR)$(PREFIX)/bin/romtool"
	@echo "已安装: $(DESTDIR)$(PREFIX)/bin/romtool"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/romtool"

clean:
	rm -f $(OBJS) $(BIN) $(TESTBIN)
	rm -rf $(TESTDIR)/tmp
