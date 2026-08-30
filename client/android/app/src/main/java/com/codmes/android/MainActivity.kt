package com.codmes.android

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private lateinit var content: LinearLayout
    private lateinit var server: EditText
    private lateinit var token: EditText
    private val http = OkHttpClient()
    private var liveSocket: WebSocket? = null
    private var liveSessionId: String? = null
    private var pendingChatMessage: String? = null
    private var transcript: TextView? = null
    private val formFactor: String
        get() = if (resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 24, 24, 24) }
        server = EditText(this).apply { hint = "Workspace server"; setText("http://10.0.2.2:8787") }
        token = EditText(this).apply { hint = "Server token (optional)" }
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(server)
        root.addView(token)
        root.addView(Button(this).apply { text = "Connect"; setOnClickListener { loadPlugins() } })
        root.addView(ScrollView(this).apply { addView(content) }, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
    }

    private fun loadPlugins(): Unit { request("/api/plugins") { response ->
        val plugins = response.getJSONArray("plugins")
        show { panel ->
            panel.addView(title("Codmes · android + $formFactor"))
            for (index in 0 until plugins.length()) {
                val plugin = plugins.getJSONObject(index)
                if (!supportsCurrentDevice(plugin)) continue
                val views = plugin.optJSONArray("views") ?: JSONArray()
                for (viewIndex in 0 until views.length()) {
                    val view = views.getJSONObject(viewIndex)
                    panel.addView(Button(this).apply {
                        text = "${plugin.getString("name")} · ${view.getString("title")}"
                        setOnClickListener {
                            if (view.optString("renderer") == "declarative") {
                                loadSurface(plugin.getString("id"))
                            } else {
                                when (view.optString("id")) {
                                    "chat" -> openChat()
                                    "notes" -> openFiles("notes")
                                    "code" -> openFiles("code")
                                    else -> showMessage("No native renderer for ${view.getString("title")}")
                                }
                            }
                        }
                    })
                }
            }
        }
    } }

    private fun openFiles(root: String): Unit { request("/api/tree?root=$root&recursive=true") { response ->
        val children = response.optJSONArray("children") ?: JSONArray()
        show { panel ->
            panel.addView(title(root.replaceFirstChar { it.uppercase() }))
            for (index in 0 until children.length()) {
                val item = children.getJSONObject(index)
                if (item.optBoolean("isDirectory")) continue
                panel.addView(Button(this).apply {
                    text = item.optString("path")
                    setOnClickListener { openFile(item.optString("path"), root) }
                })
            }
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
        }
    } }

    private fun openFile(path: String, root: String): Unit { request("/api/file?path=${encode(path)}") { response ->
        show { panel ->
            panel.addView(title(response.optString("name", path)))
            val editor = EditText(this).apply {
                setText(response.optString("content"))
                gravity = android.view.Gravity.TOP
                minLines = 18
                setHorizontallyScrolling(true)
            }
            panel.addView(editor, LinearLayout.LayoutParams(-1, 0, 1f))
            panel.addView(Button(this).apply {
                text = "Save"
                setOnClickListener {
                    requestJson("PUT", "/api/file?path=${encode(path)}", JSONObject().put("content", editor.text.toString())) {
                        showMessage("Saved $path")
                    }
                }
            })
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { openFiles(root) } })
        }
    } }

    private fun openChat() {
        disconnectChat()
        show { panel ->
            panel.addView(title("Chat"))
            transcript = text("Connecting…").also {
                it.setTextIsSelectable(true)
                panel.addView(it, LinearLayout.LayoutParams(-1, 0, 1f))
            }
            val composer = EditText(this).apply { hint = "Message" }
            panel.addView(composer)
            panel.addView(Button(this).apply {
                text = "Send"
                setOnClickListener {
                    val message = composer.text.toString().trim()
                    if (message.isNotEmpty()) {
                        appendChat("You: $message")
                        composer.text.clear()
                        submitChat(message)
                    }
                }
            })
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { disconnectChat(); loadPlugins() } })
        }
        val wsBase = server.text.toString().trimEnd('/').replaceFirst("https://", "wss://").replaceFirst("http://", "ws://")
        val tokenQuery = token.text.toString().trim().takeIf { it.isNotEmpty() }?.let { "?token=${encode(it)}" } ?: ""
        liveSocket = http.newWebSocket(Request.Builder().url("$wsBase/api/live$tokenQuery").build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(command("connect", "connect", JSONObject()).toString())
            }

            override fun onMessage(webSocket: WebSocket, value: String) {
                val envelope = JSONObject(value)
                when {
                    envelope.optString("kind") == "result" && envelope.optString("id") == "connect" ->
                        webSocket.send(command("create", "session.create", JSONObject().put("accessMode", "confirm").put("surface", "chat")).toString())
                    envelope.optString("kind") == "result" && envelope.optString("id") == "create" -> {
                        liveSessionId = envelope.optJSONObject("result")?.optString("sessionId")
                        runOnUiThread { appendChat("Connected") }
                        pendingChatMessage?.also { pendingChatMessage = null; submitChat(it) }
                    }
                    envelope.optString("kind") == "runtime.event" || envelope.optString("kind") == "hermes.event" -> {
                        val type = envelope.optString("type")
                        val eventText = envelope.optString("text")
                        if (eventText.isNotBlank() && (type.contains("delta") || type.contains("message"))) {
                            runOnUiThread { appendChat("Codmes: $eventText") }
                        }
                    }
                    envelope.optString("kind") == "error" -> runOnUiThread { appendChat("Error: ${envelope.optString("error")}") }
                }
            }

            override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
                runOnUiThread { appendChat("Connection failed: ${error.message}") }
            }
        })
    }

    private fun submitChat(message: String) {
        val sessionId = liveSessionId
        if (sessionId == null) { pendingChatMessage = message; return }
        val params = JSONObject().put("sessionId", sessionId).put("message", message).put("surface", "chat")
        liveSocket?.send(command("prompt-${System.nanoTime()}", "prompt.submit", params).toString())
    }

    private fun command(id: String, name: String, params: JSONObject) = JSONObject().put("id", id).put("command", name).put("params", params)
    private fun appendChat(value: String) { transcript?.append("\n$value") }
    private fun disconnectChat() { liveSocket?.close(1000, "leaving chat"); liveSocket = null; liveSessionId = null; transcript = null }

    private fun loadSurface(pluginId: String): Unit { request("/api/plugins/${encode(pluginId)}/view-document") { document ->
        show { panel ->
            panel.addView(title(document.optString("title", pluginId)))
            document.optString("subtitle").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
            val items = document.optJSONArray("items") ?: JSONArray()
            for (index in 0 until items.length()) {
                val item = items.getJSONObject(index)
                panel.addView(title(item.optString("title")))
                item.optString("subtitle").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
                item.optString("body").takeIf { it.isNotBlank() }?.let { panel.addView(text(it)) }
            }
            val sections = document.optJSONArray("sections") ?: JSONArray()
            for (index in 0 until sections.length()) panel.addView(title(sections.getJSONObject(index).optString("title")))
            panel.addView(Button(this).apply { text = "Back"; setOnClickListener { loadPlugins() } })
        }
    } }

    private fun supportsCurrentDevice(plugin: JSONObject): Boolean {
        return ClientCompatibility.supports(
            declaredPlatforms = strings(plugin.optJSONArray("platforms")),
            declaredFormFactors = strings(plugin.optJSONArray("formFactors")),
            currentPlatform = "android",
            currentFormFactor = formFactor
        )
    }

    private fun strings(values: JSONArray?): List<String> = (0 until (values?.length() ?: 0)).map {
        values!!.getString(it).lowercase()
    }

    private fun request(path: String, done: (JSONObject) -> Unit) = requestJson("GET", path, null, done)

    private fun requestJson(method: String, path: String, body: JSONObject?, done: (JSONObject) -> Unit) = thread {
        try {
            val builder = Request.Builder().url(server.text.toString().trimEnd('/') + path).header("Accept", "application/json")
            token.text.toString().trim().takeIf { it.isNotEmpty() }?.let { builder.header("Authorization", "Bearer $it") }
            val requestBody = body?.toString()?.toRequestBody("application/json".toMediaType())
            builder.method(method, if (method == "GET") null else requestBody ?: ByteArray(0).toRequestBody())
            val response = http.newCall(builder.build()).execute()
            val responseText = response.body?.string().orEmpty()
            if (!response.isSuccessful) error("Workspace returned ${response.code}: $responseText")
            val json = if (responseText.isBlank()) JSONObject() else JSONObject(responseText)
            runOnUiThread { done(json) }
        } catch (error: Exception) {
            runOnUiThread { showMessage(error.message ?: "Connection failed") }
        }
    }

    override fun onDestroy() { disconnectChat(); super.onDestroy() }

    private fun show(build: (LinearLayout) -> Unit) { content.removeAllViews(); build(content) }
    private fun showMessage(message: String) = show { it.addView(text(message)) }
    private fun title(value: String) = TextView(this).apply { text = value; textSize = 20f; setPadding(0, 18, 0, 8) }
    private fun text(value: String) = TextView(this).apply { text = value; textSize = 15f; setPadding(0, 4, 0, 8) }
    private fun encode(value: String) = java.net.URLEncoder.encode(value, Charsets.UTF_8.name())
}
