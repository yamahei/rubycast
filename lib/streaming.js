$(document).ready(function () {
    var position = Number($('form #position').val());

    window.setInterval(function () {
        if ($('form #playing').val() == "true") {
            position = Number($('form #position').val());
            position++;
            $('form #position').val(position);
            $('form #current_time').text(position);
        }
    }, 1000);

    if ($('form')) {
        if ($('form #loaded').val() == "true") {
            if ($('form #paused').val() == "true") {
                $('#play').show();
                $('#pause').hide();
            } else {
                if ($('form #playing').val() == "true") {
                    $('#play').hide();
                } else {
                }
            }
        } else {
            $('#play').show();
            $('#stop').hide();
            $('#pause').hide();
        }
    }

    $('#play').on('click', function () {
        var loaded = $('form #loaded').val();
        if (loaded == "true") {
            jQuery.get('/play');
            $('#stop').show();
            $('#pause').show();
            $('form #playing').val("true");
        } else {
            var file = $('form #u').val();
            var load_url = '/load?u=' + file + "&transcode=" + $('form #transcode').prop("checked");
            var audio_stream = $('form #audio_stream').val();
            var subtitle_stream = $('form #subtitle_stream').val();
            if (audio_stream) {
                load_url += "&stream=" + audio_stream;
            }
            if (subtitle_stream) {
                load_url += "&subtitle=" + subtitle_stream;
            }
            jQuery.get(load_url);
            $('#stop').show();
            $('#pause').show();
            $('form #loaded').val("true");
            $('form #playing').val("true");
        }
        $('#play').hide();
    });
    $('#stop').on('click', function () {
        jQuery.get('/stop');
        $('#stop').hide();
        $('#pause').hide();
        $('#play').show();
        $('form #loaded').val("false");
    });
    $('#pause').on('click', function () {
        jQuery.get('/pause');
        $('#play').show();
        $('#pause').hide();
        $('form #paused').val("true");
    });

    $('#position').on('change', function () {
        position = Number($('form #position').val());
        var file = $('form #u').val();
        if (file) {
            if ($('form #transcode').prop("checked")) {
                var load_url = '/load?u=' + file + "&transcode=" + $('form #transcode').prop("checked");
                var audio_stream = $('form #audio_stream').val();
                var subtitle_stream = $('form #subtitle_stream').val();
                if (audio_stream) {
                    load_url += "&stream=" + audio_stream;
                }
                if (subtitle_stream) {
                    load_url += "&subtitle=" + subtitle_stream;
                }
                load_url += '&position=' + position;

                jQuery.get(load_url);
            } else {
                jQuery.get('/seek?position=' + position);
            }
        }
    });
});