#-------------------------------------------------------------------------
#
# Makefile--
#    Makefile for src/adbmgrd/replication/libpqwalreceiver
#
# IDENTIFICATION
#    src/adbmgrd/replication/libpqwalreceiver/Makefile
#
#-------------------------------------------------------------------------

subdir = src/adbmgrd/replication/libpqwalreceiver
top_builddir = ../../../..
include $(top_builddir)/src/Makefile.global

override CPPFLAGS := -I$(srcdir) -I$(libpq_srcdir) $(CPPFLAGS)

OBJS = libpqwalreceiver.o
SHLIB_LINK = $(libpq)
SHLIB_PREREQS = submake-libpq
NAME = libpqwalreceiver

all: all-shared-lib

include $(top_srcdir)/src/Makefile.shlib

install: all installdirs install-lib

installdirs: installdirs-lib

uninstall: uninstall-lib

clean distclean maintainer-clean: clean-lib
	rm -f $(OBJS)
