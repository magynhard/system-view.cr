.PHONY: setup build run test test-ui format clean install uninstall locales generate_locales validate-metadata appimage flatpak test-packaging

PREFIX ?= /usr/local
DESTDIR ?=
CRYSTAL_FLAGS ?=
APP_ID = de.magynhard.SystemView
LANGUAGES = $(strip $(file <po/LINGUAS))
MO_FILES = $(foreach lang,$(LANGUAGES),po/$(lang)/LC_MESSAGES/$(APP_ID).mo)

setup:
	shards install
	./bin/gi-crystal

data/system-view.gresource: data/system-view.gresource.xml $(wildcard data/icons/*.svg)
	glib-compile-resources --sourcedir=data --target=$@ $<

build: locales data/system-view.gresource
	mkdir -p bin
	crystal build $(CRYSTAL_FLAGS) src/system-view.cr -o bin/system-view

run: build
	./bin/system-view

test: locales
	crystal spec

test-ui: locales data/system-view.gresource
	mkdir -p build
	dbus-run-session -- xvfb-run -a -s "-screen 0 1920x1200x24" env GDK_BACKEND=x11 GDK_SCALE=1 GDK_DPI_SCALE=1 GSK_RENDERER=cairo GTK_A11Y=none LANGUAGE=en crystal run tests/ui_smoke.cr
	dbus-run-session -- xvfb-run -a -s "-screen 0 1920x1200x24" env GDK_BACKEND=x11 GDK_SCALE=1 GDK_DPI_SCALE=1 GSK_RENDERER=cairo GTK_A11Y=none LANGUAGE=en crystal run tests/discovery_smoke.cr

format:
	crystal tool format src/ spec/ tests/*.cr

clean:
	rm -f bin/system-view data/system-view.gresource $(MO_FILES)

locales: $(MO_FILES)

po/%/LC_MESSAGES/$(APP_ID).mo: po/%/LC_MESSAGES/$(APP_ID).po
	msgfmt --check --check-format $< -o $@

generate_locales:
	xgettext --from-code=UTF-8 --language=C --keyword=translate --package-name="System View" --msgid-bugs-address="https://github.com/magynhard/system-view.cr/issues" --copyright-holder="Matthäus J. N. Beyrle" --files-from=po/POTFILES -o po/$(APP_ID).pot
	@for lang in $(LANGUAGES); do \
		msgmerge --update --backup=none --no-fuzzy-matching "po/$$lang/LC_MESSAGES/$(APP_ID).po" "po/$(APP_ID).pot" || exit $$?; \
	done

install: build
	install -Dm755 bin/system-view "$(DESTDIR)$(PREFIX)/bin/system-view"
	install -Dm644 data/$(APP_ID).desktop "$(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop"
	install -Dm644 data/$(APP_ID).metainfo.xml "$(DESTDIR)$(PREFIX)/share/metainfo/$(APP_ID).metainfo.xml"
	install -Dm644 data/icons/$(APP_ID).svg "$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APP_ID).svg"
	install -Dm644 LICENSE "$(DESTDIR)$(PREFIX)/share/licenses/$(APP_ID)/LICENSE"
	@for lang in $(LANGUAGES); do \
		install -Dm644 "po/$$lang/LC_MESSAGES/$(APP_ID).mo" "$(DESTDIR)$(PREFIX)/share/locale/$$lang/LC_MESSAGES/$(APP_ID).mo" || exit $$?; \
	done

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/system-view" "$(DESTDIR)$(PREFIX)/share/applications/$(APP_ID).desktop" "$(DESTDIR)$(PREFIX)/share/metainfo/$(APP_ID).metainfo.xml" "$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/$(APP_ID).svg" "$(DESTDIR)$(PREFIX)/share/licenses/$(APP_ID)/LICENSE"
	@for lang in $(LANGUAGES); do \
		rm -f "$(DESTDIR)$(PREFIX)/share/locale/$$lang/LC_MESSAGES/$(APP_ID).mo" || exit $$?; \
	done

validate-metadata:
	desktop-file-validate data/$(APP_ID).desktop
	appstreamcli validate --no-net --pedantic data/$(APP_ID).metainfo.xml

appimage:
	bash scripts/build-appimage.sh

flatpak:
	bash scripts/build-flatpak.sh

test-packaging:
	python3 -m unittest discover -s tests -v
