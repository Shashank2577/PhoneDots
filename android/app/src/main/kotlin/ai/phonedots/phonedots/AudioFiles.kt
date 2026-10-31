package ai.phonedots.phonedots

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Decoded mono audio as the Desert Ant SDKs expect it. */
class Pcm(val samples: FloatArray, val sampleRate: Double)

/** Decodes any audio or video soundtrack Android can read into mono float PCM. */
object AudioFiles {
  fun decode(path: String): Pcm {
    val extractor = MediaExtractor()
    val track = try {
      extractor.setDataSource(path)
      (0 until extractor.trackCount).firstOrNull {
        extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
      } ?: throw IllegalArgumentException("No audio track in ${File(path).name}")
    } catch (e: Throwable) {
      extractor.release()
      throw e
    }
    extractor.selectTrack(track)
    val format = extractor.getTrackFormat(track)
    val codec = try {
      MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!).also {
        try {
          it.configure(format, null, null, 0)
          it.start()
        } catch (e: Throwable) {
          it.release()
          throw e
        }
      }
    } catch (e: Throwable) {
      extractor.release()
      throw e
    }

    var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
    var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
    var encoding = AudioFormat.ENCODING_PCM_16BIT
    val out = FloatList()
    val info = MediaCodec.BufferInfo()
    var inputDone = false
    var outputDone = false
    try {
      while (!outputDone) {
        if (!inputDone) {
          val i = codec.dequeueInputBuffer(10_000)
          if (i >= 0) {
            val buf = codec.getInputBuffer(i)!!
            val n = extractor.readSampleData(buf, 0)
            if (n < 0) {
              codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
              inputDone = true
            } else {
              codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
              extractor.advance()
            }
          }
        }
        val o = codec.dequeueOutputBuffer(info, 10_000)
        when {
          o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            val f = codec.outputFormat
            sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            if (f.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = f.getInteger(MediaFormat.KEY_PCM_ENCODING)
          }
          o >= 0 -> {
            val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
            buf.position(info.offset)
            buf.limit(info.offset + info.size)
            appendMono(buf, encoding, channels, out)
            codec.releaseOutputBuffer(o, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
          }
        }
      }
    } finally {
      codec.stop()
      codec.release()
      extractor.release()
    }
    return Pcm(out.toArray(), sampleRate.toDouble())
  }

  private fun appendMono(buf: ByteBuffer, encoding: Int, channels: Int, out: FloatList) {
    if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
      val f = buf.asFloatBuffer()
      while (f.remaining() >= channels) {
        var sum = 0f
        repeat(channels) { sum += f.get() }
        out.add(sum / channels)
      }
    } else {
      val s = buf.asShortBuffer()
      while (s.remaining() >= channels) {
        var sum = 0f
        repeat(channels) { sum += s.get() / 32768f }
        out.add(sum / channels)
      }
    }
  }

  /** Writes mono float samples as a 16-bit PCM WAV file. */
  fun writeWav(path: String, samples: FloatArray, sampleRate: Int) {
    val data = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
    for (v in samples) data.putShort((v.coerceIn(-1f, 1f) * 32767).toInt().toShort())
    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
      put("RIFF".toByteArray()); putInt(36 + data.capacity()); put("WAVE".toByteArray())
      put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1); putInt(sampleRate)
      putInt(sampleRate * 2); putShort(2); putShort(16)
      put("data".toByteArray()); putInt(data.capacity())
    }
    FileOutputStream(path).use {
      it.write(header.array())
      it.write(data.array())
    }
  }

  private class FloatList {
    private var data = FloatArray(1 shl 16)
    private var size = 0

    fun add(v: Float) {
      if (size == data.size) data = data.copyOf(size * 2)
      data[size++] = v
    }

    fun toArray(): FloatArray = data.copyOf(size)
  }
}
