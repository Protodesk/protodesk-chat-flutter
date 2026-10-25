package com.protodesk.chat;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public final class ProtodeskChatPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
  private static final int MAX = 16 * 1024 * 1024;
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());
  private MethodChannel channel;
  private Context context;
  @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "protodesk_chat/attachment_files");
    channel.setMethodCallHandler(this);
  }
  @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null); worker.shutdown();
  }
  private String checked(String value, boolean handle) throws IOException {
    if (value == null || !value.matches(handle ? "[a-f0-9-]{36}" : "[a-f0-9]{64}")) throw new IOException();
    return value;
  }
  private File root(String scope) throws IOException {
    File dir = new File(new File(context.getNoBackupFilesDir(), "protodesk_chat_attachments"), checked(scope,false));
    if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException();
    return dir;
  }
  private File folder(String scope, String partition) throws IOException {
    File dir = new File(root(scope), checked(partition,false));
    if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException();
    return dir;
  }
  private SecretKey key(String scope, boolean create) throws Exception {
    String alias = "protodesk.chat.attachments." + checked(scope,false);
    KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
    if (store.containsAlias(alias)) return (SecretKey) store.getKey(alias, null);
    if (!create) throw new IOException();
    KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
    generator.init(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
      .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
      .setKeySize(256).build());
    return generator.generateKey();
  }
  private void remove(File file) throws IOException {
    if (file.isDirectory()) {
      File[] children = file.listFiles(); if (children == null) throw new IOException();
      for (File child : children) remove(child);
    }
    if (file.exists() && !file.delete()) throw new IOException();
  }
  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    worker.execute(() -> {
      try { Object value = perform(call); main.post(() -> result.success(value)); }
      catch (Exception error) { main.post(() -> result.error("attachment_storage_unavailable", "Protected attachment storage unavailable", null)); }
    });
  }
  private Object perform(MethodCall call) throws Exception {
    if (call.method.equals("available")) return context.getNoBackupFilesDir().isDirectory();
    String scope = checked(call.argument("scope"),false), partition = checked(call.argument("partition"),false);
    File directory = folder(scope,partition);
    if (call.method.equals("purge")) { remove(directory); return null; }
    if (call.method.equals("retain")) {
      List<String> values = call.argument("handles"); if (values == null || values.size() > 10) throw new IOException();
      Set<String> handles = new HashSet<>(); for (String h : values) handles.add(checked(h,true));
      File[] partitions = root(scope).listFiles(); if (partitions == null) throw new IOException();
      for (File dir : partitions) {
        if (!dir.getName().equals(partition)) { remove(dir); continue; }
        File[] files = dir.listFiles(); if (files == null) throw new IOException();
        for (File file : files) if (!handles.contains(file.getName())) remove(file);
      }
      return null;
    }
    String handle = checked(call.argument("handle"),true);
    File file = new File(directory,handle);
    if (call.method.equals("delete")) { remove(file); return null; }
    byte[] aad = (scope + ":" + partition + ":" + handle).getBytes(StandardCharsets.UTF_8);
    if (call.method.equals("write")) {
      byte[] bytes = call.argument("bytes"); if (bytes == null || bytes.length == 0 || bytes.length > MAX) throw new IOException();
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key(scope,true)); cipher.updateAAD(aad);
      byte[] encrypted = cipher.doFinal(bytes), iv = cipher.getIV();
      if (iv.length != 12) throw new IOException();
      File temp = new File(directory,handle + ".tmp");
      try (FileOutputStream out = new FileOutputStream(temp)) { out.write(iv); out.write(encrypted); out.getFD().sync(); }
      if (!temp.renameTo(file)) { remove(temp); throw new IOException(); }
      // Flush the directory entry as well as the file contents.
      java.io.FileDescriptor fd = android.system.Os.open(directory.getPath(), android.system.OsConstants.O_RDONLY, 0);
      try { android.system.Os.fsync(fd); } finally { android.system.Os.close(fd); }
      return null;
    }
    if (call.method.equals("read")) {
      long size = file.length(); if (size <= 28 || size > MAX + 28) throw new IOException();
      byte[] stored = new byte[(int)size];
      try (DataInputStream in = new DataInputStream(new FileInputStream(file))) { in.readFully(stored); if (in.read() != -1) throw new IOException(); }
      Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
      cipher.init(Cipher.DECRYPT_MODE,key(scope,false),new GCMParameterSpec(128,Arrays.copyOfRange(stored,0,12))); cipher.updateAAD(aad);
      return cipher.doFinal(Arrays.copyOfRange(stored,12,stored.length));
    }
    throw new IOException();
  }
}
