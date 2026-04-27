git status

git add docs/book/src/realtime.md

cd docs/book
mdbook build
cd ../..

git add docs/book
git commit -m "New chapter added Redis Stream"

git push

git subtree push --prefix docs/book/book origin gh-pages