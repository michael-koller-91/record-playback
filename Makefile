debug: main.odin
	odin build .

release: main.odin
	odin build . -o:speed
