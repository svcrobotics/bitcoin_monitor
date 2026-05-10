git status

git add docs/book/src/redis-stream.md

cd docs/book
mdbook build
cd ../..

git add docs/book
git commit -m "Update Redis Streams chapter with recovery architecture"

git push

git subtree push --prefix docs/book/book origin gh-pages