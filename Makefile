all : build

build: sandbox
	cabal install
	chmod +x wrap/expressionTesting.sh
	ln -s wrap/expressionTesting.sh expressionTesting || true

sandbox : .cabal-sandbox

.cabal-sandbox :
	cabal sandbox init

install:
	cabal install

clean:
	cabal clean
	rm -rf dist || true
	rm expressionTesting || true

clean-all: clean
	find -name '*.hi' -exec rm {} \;
	find -name '*.o' -exec rm {} \;
	cabal sandbox delete

env : build
	chmod +x wrap/env.sh
	wrap/env.sh

sdist :
	cabal sdist

nixcheck : sdist
	chmod +x nixcheck.sh
	./nixcheck.sh

test : sandbox
	cabal configure --enable-tests
	chmod +x wrap/env.sh
	./wrap/env.sh -c "cabal test --show-details=always"