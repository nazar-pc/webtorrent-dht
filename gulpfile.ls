/**
 * @package   WebTorrent DHT
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
browserify	= require('browserify')
del			= require('del')
gulp		= require('gulp')
rename		= require('gulp-rename')
tap			= require('gulp-tap')
uglify-es	= require('uglify-es')
uglify		= require('gulp-uglify/composer')(uglify-es, console)
DESTINATION	= 'dist'

gutil = require('gulp-util')

gulp
	.task('build', ['clean', 'browserify', 'minify'])
	.task('browserify', ['clean'], ->
		gulp.src('webtorrent-dht.js', {read: false})
			.pipe(tap(
				(file) !->
					file.contents	=
						browserify(
							entries		: file.path
							standalone	: 'webtorrent_dht'
						)
							.bundle()
			))
			.pipe(rename(
				suffix: '.browser'
			))
			.pipe(gulp.dest(DESTINATION))
	)
	.task('clean', ->
		del(DESTINATION)
	)
	.task('minify', ['browserify'], ->
		gulp.src("#DESTINATION/*.js")
			.pipe(uglify())
			.on('error', (err) !-> gutil.log(gutil.colors.red('[Error]'), err.toString()))
			.pipe(rename(
				suffix: '.min'
			))
			.pipe(gulp.dest(DESTINATION))
	)
